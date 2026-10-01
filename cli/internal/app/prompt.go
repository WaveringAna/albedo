package app

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"albedo/cli/internal/daemon"
)

type PromptOptions struct {
	Prompt, SessionID, Workspace, Model string
	Timeout                             time.Duration
}
type PromptResult struct{ SessionID, Answer string }

// RunPrompt waits for the reply to this invocation's turn. Zero timeout is unlimited.
func (s *Service) RunPrompt(ctx context.Context, options PromptOptions) (PromptResult, error) {
	prompt, sessionID, cwd, model, timeout := options.Prompt, options.SessionID, options.Workspace, options.Model, options.Timeout
	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}
	conn, err := s.Connect(ctx)
	if err != nil {
		return PromptResult{}, err
	}
	var choice modelChoice
	if model != "" {
		profiles, profileErr := daemon.ProviderProfiles(ctx, conn)
		if profileErr != nil {
			return PromptResult{}, profileErr
		}
		if choice, err = chooseModel(configuredModels(ctx, conn, profiles), profiles.Active, model); err != nil {
			return PromptResult{}, err
		}
	}
	if sessionID != "" {
		if sessionID, err = resolveSession(ctx, conn, sessionID); err != nil {
			return PromptResult{}, err
		}
	}
	if sessionID == "" {
		create := map[string]string{"workspace": cwd}
		if model != "" {
			create["provider"], create["model"] = choice.provider, choice.model
		}
		session, createErr := daemon.Request[daemon.Session](ctx, conn, "/sessions", create)
		if createErr != nil {
			return PromptResult{}, createErr
		}
		sessionID = session.ID
	} else if model != "" {
		if switchErr := switchModel(ctx, conn, sessionID, choice); switchErr != nil {
			return PromptResult{}, switchErr
		}
	}

	client := daemon.NewChatClient(conn, sessionID)
	answer, err := awaitReply(ctx, client, prompt)
	switch {
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return PromptResult{}, fmt.Errorf("timed out after %s and stopped the turn; the session is %s", timeout, sessionID)
	case ctx.Err() != nil:
		return PromptResult{}, fmt.Errorf("interrupted; the session is %s", sessionID)
	}
	if err != nil {
		return PromptResult{}, err
	}
	return PromptResult{SessionID: sessionID, Answer: answer}, nil
}

// awaitReply sends prompt and answers the last assistant text of the turn it
// starts once the session is idle again, or the error that ended the turn.
func awaitReply(ctx context.Context, client *daemon.ChatClient, prompt string) (string, error) {
	streamCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	var (
		mu      sync.Mutex
		started bool // our prompt has reached the transcript
		owned   bool // the latest observed live turn belongs to this invocation
		answer  string
		failure error
	)
	// Cleanup uses its own deadline even when the operation's context is canceled.
	defer func() {
		if ctx.Err() == nil {
			return
		}
		mu.Lock()
		interrupt := owned
		mu.Unlock()
		if interrupt {
			interruptCtx, stop := context.WithTimeout(context.Background(), 5*time.Second)
			defer stop()
			_, _ = client.Interrupt(interruptCtx)
		}
	}()
	ready := make(chan struct{})
	streamDone := make(chan error, 1)
	go func() {
		streamDone <- client.Stream(streamCtx, 0, func(event daemon.StreamEvent) error {
			mu.Lock()
			defer mu.Unlock()
			switch {
			case event.Type == daemon.EventReset:
				select {
				case <-ready:
				default:
					close(ready) // the snapshot is read; later events are live
				}
			case event.Replayed:
			case event.Type == daemon.EventUser:
				owned = event.ClientID == client.ClientID()
				started = started || owned
			case !owned:
			case event.Type == daemon.EventMessage:
				answer, failure = event.Text, nil
			case event.Type == daemon.EventError:
				failure = errors.New(event.Text)
			case event.Type == daemon.EventInterrupted:
				failure = errors.New("the turn was interrupted")
			case event.Type == daemon.EventRetry:
				failure = nil
			}
			return nil
		})
	}()
	select {
	case <-ready:
	case err := <-streamDone:
		return "", fmt.Errorf("could not follow the session: %w", err)
	case <-ctx.Done():
		return "", ctx.Err()
	}
	if _, err := client.Send(ctx, prompt, nil); err != nil {
		return "", err
	}

	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()
	idleBefore := false
	for {
		mu.Lock()
		turnSeen := started
		mu.Unlock()
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case err := <-streamDone:
			return "", fmt.Errorf("lost the session stream before the turn finished: %v", err)
		case <-ticker.C:
		}
		if !turnSeen {
			continue
		}
		// Idle after our prompt reached the transcript means its turn is over;
		// idle twice in a row gives the stream time to deliver its last events.
		status, err := client.GetStatus(ctx)
		if err != nil {
			return "", err
		}
		if !status.Idle || !idleBefore {
			idleBefore = status.Idle
			continue
		}
		mu.Lock()
		defer mu.Unlock()
		switch {
		case failure != nil:
			return "", failure
		case answer == "":
			return "", errors.New("the turn ended without an assistant reply")
		}
		return answer, nil
	}
}
