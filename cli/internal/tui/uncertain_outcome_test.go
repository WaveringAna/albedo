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
			image := &daemon.ImageAttachment{}
			m.AttachedImage = image
			var commands []tea.Cmd
			m.submitInput("check this", &commands)
			m.pendingUsers[0].Queued = queued
			m.TextArea.Reset()
			m.interruptDeferred = true

			m, cmd := m.Update(ChatTurnSentMsg{
				SessionID: "s", Generation: m.Generation, Prompt: "check this", Image: image,
				Err: fmt.Errorf("send: %w", &daemon.UncertainOutcomeError{Operation: "submit", Cause: io.ErrUnexpectedEOF}),
			})
			if cmd != nil || m.isSending || m.interruptDeferred {
				t.Fatal("uncertain acknowledgement must settle sending without another mutation")
			}
			if m.TextArea.Value() != "" || m.AttachedImage != nil {
				t.Fatal("uncertain send restored a duplicate prompt or image")
			}
			if len(m.pendingUsers) != 1 || m.pendingUsers[0].Image != image || m.pendingUsers[0].Queued != queued {
				t.Fatalf("lost pending submission: %+v", m.pendingUsers)
			}
			if len(m.Notices) != 1 || m.Notices[0].Message == "" {
				t.Fatalf("missing uncertainty guidance: %+v", m.Notices)
			}

			for _, event := range []daemon.StreamEvent{
				{Type: daemon.EventUser, Text: "check this", Source: "chat", ClientID: m.client.ClientID()},
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
	image := &daemon.ImageAttachment{}
	m.AttachedImage = image
	var commands []tea.Cmd
	m.submitInput("already accepted", &commands)
	m.TextArea.Reset()
	for _, event := range []daemon.StreamEvent{
		{Type: daemon.EventUser, Text: "already accepted", Source: "chat", ClientID: m.client.ClientID()},
		{Type: daemon.EventCommitted, Seq: 1},
	} {
		m, _ = m.Update(ChatStreamEventMsg{SessionID: "s", Generation: m.Generation, Event: event})
	}

	m, cmd := m.Update(ChatTurnSentMsg{
		SessionID: "s", Generation: m.Generation, Prompt: "already accepted", Image: image,
		Err: &daemon.UncertainOutcomeError{Operation: "submit", Cause: io.EOF},
	})
	if cmd != nil || m.isSending || len(m.pendingUsers) != 0 || m.TextArea.Value() != "" || m.AttachedImage != nil {
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

func TestUncertainContinueDoesNotChangePendingOrRestorePrompt(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.pendingUsers = []PendingUserTurn{{Text: "already waiting", Queued: true}}
	m.isSending = true
	m, cmd := m.Update(ChatTurnSentMsg{
		SessionID: "s", Generation: m.Generation, Continue: true, Prompt: ".",
		Err: &daemon.UncertainOutcomeError{Operation: "continue", Cause: io.EOF},
	})
	if cmd != nil || m.isSending || m.TextArea.Value() != "" || len(m.pendingUsers) != 1 {
		t.Fatal("uncertain continue restored or removed a user submission")
	}
	if len(m.Notices) != 1 || m.Notices[0].Message == "" {
		t.Fatalf("continue reported definite rejection: %+v", m.Notices)
	}
}

func TestDefiniteRejectionRestoresPromptAndImage(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	image := &daemon.ImageAttachment{}
	m.pendingUsers = []PendingUserTurn{{Text: "try this", Image: image}}
	m, _ = m.Update(ChatTurnSentMsg{
		SessionID: "s", Generation: m.Generation, Prompt: "try this", Image: image,
		Err: errors.New("submission refused"),
	})
	if len(m.pendingUsers) != 0 || m.TextArea.Value() != "try this" || m.AttachedImage != image {
		t.Fatal("definite rejection did not restore the user's input")
	}
}

func TestUncertainCreationKeepsCurrentSession(t *testing.T) {
	conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, "")
	session := &daemon.Session{ID: "current"}
	m := NewAppModel(conn, config.Profiles{}, session, "", false, nil)
	t.Cleanup(m.Chat.Close)
	updated, cmd := m.Update(sessionCreatedMsg{Err: &daemon.UncertainOutcomeError{Operation: "create session", Cause: io.EOF}})
	m = updated.(AppModel)
	if cmd != nil || m.ActiveSession != session || m.Chat.SessionID != session.ID || m.State != AppStateChat {
		t.Fatal("uncertain creation changed the active session or resubmitted creation")
	}
	if len(m.Chat.Notices) != 1 || m.Chat.Notices[0].Message == "" {
		t.Fatalf("missing creation guidance: %+v", m.Chat.Notices)
	}
}

func TestUncertainCommandKeepsSessionAndEffort(t *testing.T) {
	conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, "")
	session := &daemon.Session{ID: "current", Effort: "low"}
	m := NewAppModel(conn, config.Profiles{}, session, "", false, nil)
	t.Cleanup(m.Chat.Close)
	updated, cmd := m.Update(commandExecutedMsg{Name: "/effort", Effort: "high", Err: &daemon.UncertainOutcomeError{Operation: "command", Cause: io.EOF}})
	m = updated.(AppModel)
	if cmd != nil || m.ActiveSession != session || m.ActiveSession.Effort != "low" || m.Chat.Effort != "low" || m.State != AppStateChat {
		t.Fatal("uncertain command applied an unconfirmed result or resubmitted the command")
	}
	if len(m.Chat.Notices) != 1 || m.Chat.Notices[0].Message == "" {
		t.Fatalf("missing command guidance: %+v", m.Chat.Notices)
	}
}

func TestUncertainSignInDoesNotRestartOrOpenBrowser(t *testing.T) {
	conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, "")
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
