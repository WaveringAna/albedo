package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
)

// promptCommand runs one prompt to the end of its turn and prints the reply.
// A zero timeout waits as long as the turn takes.
func promptCommand(prompt, sessionID, cwd, model string, timeout time.Duration) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}
	conn, err := daemon.Ensure(config.HomeDir(), findProjectRoot(), replaceStale)
	if err != nil {
		return err
	}
	var choice modelChoice
	if model != "" {
		profiles, profileErr := daemon.ProviderProfiles(ctx, conn)
		if profileErr != nil {
			return profileErr
		}
		if choice, err = chooseModel(configuredModels(ctx, conn, profiles), profiles.Active, model); err != nil {
			return err
		}
	}
	if sessionID == "" {
		create := map[string]string{"workspace": cwd}
		if model != "" {
			create["provider"], create["model"] = choice.provider, choice.model
		}
		session, createErr := daemon.Request[daemon.Session](ctx, conn, "/sessions", create)
		if createErr != nil {
			return createErr
		}
		sessionID = session.ID
	} else if model != "" {
		if switchErr := switchModel(ctx, conn, sessionID, choice); switchErr != nil {
			return switchErr
		}
	}

	client := daemon.NewChatClient(conn, sessionID)
	answer, err := awaitReply(ctx, client, prompt)
	switch {
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return fmt.Errorf("timed out after %s and stopped the turn; the session is %s", timeout, sessionID)
	case ctx.Err() != nil:
		return fmt.Errorf("interrupted; the session is %s", sessionID)
	}
	if err != nil {
		return err
	}
	fmt.Println(answer)
	return nil
}

// awaitReply sends prompt and answers the last assistant text of the turn it
// starts once the session is idle again, or the error that ended the turn.
func awaitReply(ctx context.Context, client *daemon.ChatClient, prompt string) (string, error) {
	streamCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	var (
		mu      sync.Mutex
		started bool // our prompt has reached the transcript
		answer  string
		failure error
	)
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
				started = started || event.ClientID == client.ClientID()
			case !started:
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
			// Ctrl-C or the timeout stops our turn too, rather than leaving it
			// running unseen; a turn still queued behind another is left alone.
			if turnSeen {
				interruptCtx, stop := context.WithTimeout(context.Background(), 5*time.Second)
				defer stop()
				_, _ = client.Interrupt(interruptCtx)
			}
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
