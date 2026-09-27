// Notices must be cleared or carried at the correct TUI turn boundary.
package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestNoticeClearedOnUserMessageSubmit(t *testing.T) {
	session := daemon.Session{
		ID:        "s1",
		Workspace: "/test/workspace",
		Provider:  "claude",
		Model:     "claude-3-7-sonnet",
	}
	app := NewAppModel(nil, config.Profiles{}, &session, "/test/workspace", false)
	updated, _ := app.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	app = updated.(AppModel)

	// Simulate profilesLoadedMsg (which sets the login/new-session notice)
	msg := profilesLoadedMsg{
		Profiles: config.Profiles{},
		Provider: "antigravity",
		Gen:      app.ProfileGen,
	}
	updated, _ = app.Update(msg)
	app = updated.(AppModel)

	expectedNotice := "antigravity selected for new sessions; use /model to switch this session from claude"
	if len(app.Chat.Notices) != 1 || app.Chat.Notices[0].Message != expectedNotice {
		t.Fatalf("expected chat.Notices to contain %q, got %#v", expectedNotice, app.Chat.Notices)
	}
	if !strings.Contains(ansi.Strip(app.Chat.View()), expectedNotice) {
		t.Fatalf("expected notice to be displayed in chat view")
	}

	// Now user enters a new message and submits
	app.Chat.TextArea.SetValue("how's the weather?")
	updated, _ = app.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	app = updated.(AppModel)

	if len(app.Chat.Notices) != 0 {
		t.Fatalf("expected chat.Notices to be cleared on new message, got %#v", app.Chat.Notices)
	}
	if strings.Contains(ansi.Strip(app.Chat.View()), expectedNotice) {
		t.Fatalf("expected notice to disappear from chat view after sending message")
	}
}

func TestNoticeClearedOnStreamEventUser(t *testing.T) {
	session := daemon.Session{
		ID:        "s1",
		Workspace: "/test/workspace",
		Provider:  "codex",
		Model:     "gpt-5",
	}
	app := NewAppModel(nil, config.Profiles{}, &session, "/test/workspace", false)
	updated, _ := app.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	app = updated.(AppModel)

	app.AddNotice("some notice for new sessions")

	if len(app.Chat.Notices) != 1 || app.Chat.Notices[0].Message != "some notice for new sessions" {
		t.Fatalf("expected Chat.Notices to have the added notice")
	}

	// Receiving a live user event should clear the notice
	streamMsg := ChatStreamEventMsg{
		SessionID:  "s1",
		Generation: app.Chat.Generation,
		Event: daemon.StreamEvent{
			Type: daemon.EventUser,
			Text: "hello from another client",
		},
	}
	updated, _ = app.Update(streamMsg)
	app = updated.(AppModel)

	if len(app.Chat.Notices) != 0 {
		t.Fatalf("expected chat.Notices to be cleared, got %#v", app.Chat.Notices)
	}
}

func TestPickerNoticesHandedOffToNewSession(t *testing.T) {
	app := NewAppModel(nil, config.Profiles{}, nil, "/test/workspace", false)
	app.AddNotice("antigravity selected for new sessions")

	if len(app.Notices) != 1 {
		t.Fatalf("expected 1 notice on AppModel when no active session, got %#v", app.Notices)
	}

	// Creating a session moves notices to the active ChatModel
	session := daemon.Session{
		ID:        "new-session",
		Workspace: "/test/workspace",
		Provider:  "antigravity",
	}
	createdMsg := sessionCreatedMsg{
		Session: session,
		Gen:     app.SessionGen,
	}
	updated, _ := app.Update(createdMsg)
	app = updated.(AppModel)

	if len(app.Notices) != 0 {
		t.Fatalf("expected app.Notices to be handed off and cleared, got %#v", app.Notices)
	}
	if len(app.Chat.Notices) != 1 || app.Chat.Notices[0].Message != "antigravity selected for new sessions" {
		t.Fatalf("expected chat.Notices to inherit notice from picker, got %#v", app.Chat.Notices)
	}
}
