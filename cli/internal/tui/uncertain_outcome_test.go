// Lost acknowledgements can race stream echoes; a daemon E2E cannot inspect
// whether the detached TUI restored a duplicate prompt or retained its pending image.
package tui

import (
	"errors"
	"fmt"
	"io"
	"testing"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
)

func TestUncertainSubmissionRetainsPendingUntilStreamEcho(t *testing.T) {
	for _, queued := range []bool{false, true} {
		t.Run(fmt.Sprintf("queued=%v", queued), func(t *testing.T) {
			m := newTestChatModel(t, &daemon.Session{ID: "s"})
			m.SetSize(80, 30)
			image := daemon.ImageAttachment{Data: "image"}
			var commands []tea.Cmd
			m.submitInput("check this "+m.Images.add(pastedImage{ImageAttachment: image}), &commands)
			handle := m.pendingUsers[0].Handle
			m.pendingUsers[0].Queued = queued
			m.TextArea.Reset()
			m.interruptDeferred = true

			m, cmd := m.Update(ChatTurnSentMsg{
				SessionID: "s", Generation: m.Generation, Prompt: "check this [Image #1]", Images: []daemon.ImageAttachment{image},
				Handle: handle, OperationID: handle.ID(),
				Err: fmt.Errorf("send: %w", &daemon.UncertainOutcomeError{Operation: "submit", Cause: io.ErrUnexpectedEOF, Handle: handle}),
			})
			if cmd == nil || m.isSending || m.interruptDeferred {
				t.Fatal("uncertain acknowledgement must settle sending and schedule receipt recovery")
			}
			if m.TextArea.Value() != "" || len(m.Images.byNumber) != 0 {
				t.Fatal("uncertain send restored a duplicate prompt or image")
			}
			if len(m.pendingUsers) != 1 || len(m.pendingUsers[0].Images) != 1 || m.pendingUsers[0].Images[0] != image || m.pendingUsers[0].Queued != queued {
				t.Fatalf("lost pending submission: %+v", m.pendingUsers)
			}
			if len(m.Notices) != 1 || m.Notices[0].Message == "" {
				t.Fatalf("missing uncertainty guidance: %+v", m.Notices)
			}

			for _, event := range []daemon.StreamEvent{
				{Type: daemon.EventUser, Text: "check this", Source: "chat", OperationID: m.pendingUsers[0].OperationID},
				{Type: daemon.EventCommitted, Seq: 1},
			} {
				m, _ = m.Update(ChatStreamEventMsg{SessionID: "s", Generation: m.Generation, Event: event})
			}
			if len(m.pendingUsers) != 0 || len(m.Notices) != 0 {
				t.Fatalf("stream echo did not reconcile pending submission: pending=%+v notices=%+v", m.pendingUsers, m.Notices)
			}
			users := 0
			for _, entry := range m.History.Entries() {
				if entry.Kind == EntryUser && entry.Text == "check this" {
					users++
				}
			}
			if users != 1 {
				t.Fatalf("want one committed user message, got %d", users)
			}
		})
	}
}

func TestStreamEchoBeforeUncertainAcknowledgementDoesNotRestoreSubmission(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 30)
	image := daemon.ImageAttachment{Data: "image"}
	var commands []tea.Cmd
	m.submitInput("already accepted "+m.Images.add(pastedImage{ImageAttachment: image}), &commands)
	handle := m.pendingUsers[0].Handle
	m.TextArea.Reset()
	for _, event := range []daemon.StreamEvent{
		{Type: daemon.EventUser, Text: "already accepted", Source: "chat", OperationID: m.pendingUsers[0].OperationID},
		{Type: daemon.EventCommitted, Seq: 1},
	} {
		m, _ = m.Update(ChatStreamEventMsg{SessionID: "s", Generation: m.Generation, Event: event})
	}

	m, cmd := m.Update(ChatTurnSentMsg{
		SessionID: "s", Generation: m.Generation, Prompt: "already accepted [Image #1]", Images: []daemon.ImageAttachment{image},
		Handle: handle, OperationID: handle.ID(),
		Err: &daemon.UncertainOutcomeError{Operation: "submit", Cause: io.EOF, Handle: handle},
	})
	if cmd != nil || m.isSending || len(m.pendingUsers) != 0 || m.TextArea.Value() != "" || len(m.Images.byNumber) != 0 {
		t.Fatal("late uncertain acknowledgement restored or resubmitted an echoed message")
	}
	users := 0
	for _, entry := range m.History.Entries() {
		if entry.Kind == EntryUser && entry.Text == "already accepted" {
			users++
		}
	}
	if users != 1 {
		t.Fatalf("want one committed user message, got %d", users)
	}
}

func TestUncertainCommandKeepsSessionAndEffort(t *testing.T) {
	conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, nil)
	session := &daemon.Session{ID: "current", Effort: "low"}
	m := NewAppModel(conn, config.Profiles{}, session, "", false, nil)
	t.Cleanup(m.Chat.Close)
	updated, cmd := m.Update(commandExecutedMsg{Name: "/effort", Effort: "high", Err: &daemon.UncertainOutcomeError{Operation: "command", Cause: io.EOF}})
	m = updated.(*AppModel)
	if cmd != nil || m.ActiveSession != session || m.ActiveSession.Effort != "low" || m.Chat.Effort != "low" || m.State != AppStateChat {
		t.Fatal("uncertain command applied an unconfirmed result or resubmitted the command")
	}
	if len(m.Chat.Notices) != 1 || m.Chat.Notices[0].Message == "" {
		t.Fatalf("missing command guidance: %+v", m.Chat.Notices)
	}
}

func TestUncertainSignInDoesNotRestartOrOpenBrowser(t *testing.T) {
	conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, nil)
	opened := false
	m := NewLoginModel(conn, "", func(string) { opened = true })
	m.Step = StepOAuth
	m, cmd := m.Update(signInStartedMsg{Gen: m.Generation, Err: &daemon.UncertainOutcomeError{Operation: "sign-in", Cause: io.EOF}})
	if cmd != nil || opened || m.LoginID != "" || m.Error == "" {
		t.Fatalf("uncertain sign-in restarted or lost its guidance: %q", m.Error)
	}
	m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if cmd != nil || m.LoginID != "" {
		t.Fatal("Enter automatically restarted an uncertain sign-in")
	}
}

func TestInvalidSessionSnapshotKeepsConfirmedGlances(t *testing.T) {
	conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, nil)
	m := NewAppModel(conn, config.Profiles{}, &daemon.Session{ID: "current"}, "", false, nil)
	t.Cleanup(m.Chat.Close)
	m.Chat.Glances = []PageGlance{{Title: "confirmed"}}
	updated, _ := m.Update(ChatStatusMsg{
		SessionID: m.Chat.SessionID, Generation: m.Chat.Generation,
		Err: invalidResponseOutcome("/work", "page", errors.New("missing page")),
	})
	m = updated.(*AppModel)
	if len(m.Chat.Glances) != 1 || m.Chat.Glances[0].Title != "confirmed" {
		t.Fatal("invalid snapshot replaced confirmed glances")
	}
}

func TestInvalidOpenResponseDoesNotRefreshSettings(t *testing.T) {
	conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, nil)
	m := NewAppModel(conn, config.Profiles{}, &daemon.Session{ID: "current"}, "", false, nil)
	t.Cleanup(m.Chat.Close)
	_, cmd := m.Update(uiSavedMsg{Open: true, Err: invalidResponseOutcome("record open", "thinking", errors.New("missing preference"))})
	if cmd != nil {
		t.Fatal("invalid open response scheduled a settings refresh")
	}
}

func TestUncertainWebhookStepRetainsConfirmedSecretWithoutRefresh(t *testing.T) {
	m := loadedWebhooksPage(t)
	m.Saving = true
	secret := &webhookSecret{Hook: "ci", Session: "s", Secret: "confirmed-secret"}
	m, cmd := m.Update(webhooksSavedMsg{
		Gen: m.Generation, Reveal: secret,
		Err: invalidResponseOutcome("/webhooks", "hook", errors.New("missing hook")),
	})
	if cmd != nil || m.Reveal != secret || m.Saving || m.Loading {
		t.Fatal("uncertain later step lost the confirmed secret or scheduled a refresh")
	}
}

func invalidResponseOutcome(operation, field string, cause error) error {
	return &daemon.UncertainOutcomeError{Operation: operation, Cause: &daemon.ProtocolError{
		Code: "invalid_response", Operation: operation, Field: field, Cause: cause,
	}}
}

func TestIdenticalPendingTurnsReconcileByOperationID(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	var commands []tea.Cmd
	m.submitInput("same message", &commands)
	first := m.pendingUsers[0].OperationID
	m.submitInput("same message", &commands)
	second := m.pendingUsers[1].OperationID
	m, _ = m.Update(ChatTurnSentMsg{SessionID: "s", Generation: m.Generation, OperationID: second, Handle: m.pendingUsers[1].Handle, Queued: true, OK: true})
	if m.pendingUsers[0].Queued || !m.pendingUsers[1].Queued {
		t.Fatal("admission result matched the wrong identical message")
	}
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventUser, Text: "same message", OperationID: second})
	if len(m.pendingUsers) != 1 || m.pendingUsers[0].OperationID != first {
		t.Fatal("stream echo retired the wrong identical message")
	}
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventUser, Text: "same message", OperationID: first})
	if len(m.pendingUsers) != 0 {
		t.Fatal("original pending message was not reconciled")
	}
}

// A timer scheduled before expiry may arrive afterward; rejecting it in the
// model prevents the timer from issuing a receipt query.
func TestScheduledReceiptPollStopsAfterExpiry(t *testing.T) {
	for _, prompt := range []string{"waiting input", "."} {
		t.Run(prompt, func(t *testing.T) {
			m := newTestChatModel(t, &daemon.Session{ID: "s"})
			image := daemon.ImageAttachment{Data: "image"}
			if prompt != "." {
				prompt += " " + m.Images.add(pastedImage{ImageAttachment: image})
			}
			var commands []tea.Cmd
			m.submitInput(prompt, &commands)
			var handle *daemon.OperationHandle
			if prompt == "." {
				for _, pending := range m.pendingContinuations {
					handle = pending.Handle
				}
			} else {
				handle = m.pendingUsers[0].Handle
			}
			tick := ChatOperationPollMsg{SessionID: "s", Generation: m.Generation, Handle: handle}
			m, command := m.Update(ChatOperationResolvedMsg{
				SessionID: "s", Generation: m.Generation, Handle: handle,
				Err: &daemon.APIError{StatusCode: 410, Code: "operation_expired"},
			})
			if command != nil {
				t.Fatal("expiry scheduled another receipt poll")
			}
			m, command = m.Update(tick)
			if command != nil || m.operationRecoverable(handle.ID()) {
				t.Fatal("already scheduled tick restarted expired receipt recovery")
			}
			if prompt != "." && (len(m.pendingUsers) != 1 || m.pendingUsers[0].Handle != handle || len(m.pendingUsers[0].Images) != 1 || m.pendingUsers[0].Images[0] != image) {
				t.Fatal("expiry lost the original submission or attachment")
			}
		})
	}
}
