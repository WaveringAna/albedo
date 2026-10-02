package app

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"slices"
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
	if capabilityErr := daemon.CheckCapability(ctx, conn, "submission_cancellation", "prompt submission cancellation"); capabilityErr != nil {
		return PromptResult{}, capabilityErr
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
		session, createErr := daemon.CreateSession(ctx, conn, create)
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
	if err == nil {
		return PromptResult{SessionID: sessionID, Answer: answer}, nil
	}
	if _, uncertain := errors.AsType[*daemon.UncertainOutcomeError](err); uncertain {
		return PromptResult{}, fmt.Errorf("%w; the session is %s", err, sessionID)
	}
	switch {
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return PromptResult{}, fmt.Errorf("timed out after %s; %v; the session is %s", timeout, err, sessionID)
	case ctx.Err() != nil:
		return PromptResult{}, fmt.Errorf("interrupted; %v; the session is %s", err, sessionID)
	}
	return PromptResult{}, err
}

// awaitReply follows the logical turn containing this submission. The actor
// publishes membership before any worker events, and completion after them.
func awaitReply(ctx context.Context, client *daemon.ChatClient, prompt string) (answer string, failure error) {
	var identity [16]byte
	if _, err := rand.Read(identity[:]); err != nil {
		return "", err
	}
	submissionID := hex.EncodeToString(identity[:])
	streamCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	submitted := false
	defer func() {
		if failure == nil || !submitted {
			return
		}
		cleanupCtx, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		outcome, err := client.CancelSubmission(cleanupCtx, submissionID)
		if err != nil {
			failure = fmt.Errorf("%w; cancellation unconfirmed: %v", failure, err)
			return
		}
		switch outcome {
		case "cancelled_queued":
			failure = fmt.Errorf("%w; queued submission cancelled", failure)
		case "interrupt_requested":
			failure = fmt.Errorf("%w; interruption requested for the turn", failure)
		case "shared_running":
			failure = fmt.Errorf("%w; the shared turn is still running", failure)
		case "not_pending":
			failure = fmt.Errorf("%w; submission is no longer pending", failure)
		}
	}()
	ready := make(chan struct{})
	events := make(chan daemon.StreamEvent, 64)
	streamDone := make(chan error, 1)
	go func() {
		streamDone <- client.Stream(streamCtx, 0, func(event daemon.StreamEvent) error {
			if event.Type == daemon.EventReset {
				select {
				case <-ready:
				default:
					close(ready)
				}
			}
			if event.Replayed {
				return nil
			}
			select {
			case events <- event:
				return nil
			case <-streamCtx.Done():
				return streamCtx.Err()
			}
		})
	}()
	select {
	case <-ready:
	case err := <-streamDone:
		return "", fmt.Errorf("could not follow the session: %w", err)
	case <-ctx.Done():
		return "", ctx.Err()
	}
	// A failed request can already have reached the actor. Cleanup always uses
	// its identity, so it cannot interrupt a different client's turn.
	submitted = true
	if _, err := client.SendSubmission(ctx, prompt, submissionID); err != nil {
		return "", err
	}
	turnID := ""
	// Discard the initial reset already acknowledged before submission.
	initialReset := true
	for {
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case err := <-streamDone:
			return "", fmt.Errorf("lost the session stream before the turn finished: %v", err)
		case event := <-events:
			if event.Type == daemon.EventReset && initialReset {
				initialReset = false
				continue
			}
			if event.Type == daemon.EventReset {
				return "", errors.New("session stream reset before the submission completed; outcome uncertain")
			}
			if event.Type == daemon.EventTurnMembership && slices.Contains(event.SubmissionIDs, submissionID) {
				turnID = event.TurnID
			}
			if turnID == "" {
				continue
			}
			switch event.Type {
			case daemon.EventMessage:
				answer, failure = event.Text, nil
			case daemon.EventError:
				failure = errors.New(event.Text)
			case daemon.EventInterrupted:
				failure = errors.New("the turn was interrupted")
			case daemon.EventRetry:
				failure = nil
			case daemon.EventTurnCompleted:
				if event.TurnID != turnID {
					continue
				}
				if failure != nil {
					return "", failure
				}
				if answer == "" {
					return "", errors.New("the turn ended without an assistant reply")
				}
				return answer, nil
			}
		}
	}
}
