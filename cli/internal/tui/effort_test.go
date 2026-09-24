package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func TestChatHeaderDisplaysModelAndEffort(t *testing.T) {
	session := &daemon.Session{
		ID:        "s1",
		Workspace: "/test/workspace",
		Model:     "gemini-3.8-flash",
		Effort:    "high",
		Provider:  "antigravity",
	}
	m := NewChatModel(session, nil)
	m.SetSize(120, 30)

	view := ansi.Strip(m.View())
	if !strings.Contains(view, "gemini-3.8-flash:high") {
		t.Fatalf("expected header to contain 'gemini-3.8-flash:high', got:\n%s", view)
	}

	// When effort is empty, it displays only the model
	sessionNoEffort := &daemon.Session{
		ID:        "s2",
		Workspace: "/test/workspace",
		Model:     "gpt-4o",
		Provider:  "openai",
	}
	m2 := NewChatModel(sessionNoEffort, nil)
	m2.SetSize(120, 30)

	view2 := ansi.Strip(m2.View())
	if !strings.Contains(view2, "gpt-4o") {
		t.Fatalf("expected header to contain 'gpt-4o', got:\n%s", view2)
	}
	if strings.Contains(view2, "gpt-4o:") {
		t.Fatalf("expected header not to have colon suffix when effort is empty, got:\n%s", view2)
	}
}

func TestStatusNoteIncludesEffortWhenSet(t *testing.T) {
	session := &daemon.Session{
		ID:        "s1",
		Workspace: "/test/workspace",
		Model:     "gemini-3.8-flash",
		Effort:    "medium",
	}
	m := NewChatModel(session, nil)
	m.SetSize(120, 30)

	m.handleSubmittedCommand("/status", nil)

	found := false
	for _, entry := range m.History.Entries() {
		if strings.Contains(entry.Text, "effort: medium") {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("expected /status to record 'effort: medium' in history entry")
	}
}

func TestAppModelUpdatesEffortFromCommandExecution(t *testing.T) {
	session := daemon.Session{
		ID:        "s1",
		Workspace: "/test/workspace",
		Model:     "gemini-3.8-flash",
		Effort:    "medium",
	}
	app := NewAppModel(nil, config.Profiles{}, &session, "/test/workspace", false)
	if app.Chat.Effort != "medium" {
		t.Fatalf("expected initial chat effort 'medium', got %q", app.Chat.Effort)
	}

	// Simulate command execution update for /effort high
	msg := commandExecutedMsg{
		Name:    "/effort",
		Message: "reasoning effort set to high",
		Effort:  "high",
		Gen:     app.CommandGen,
	}
	updated, _ := app.Update(msg)
	app = updated.(AppModel)

	if app.ActiveSession.Effort != "high" {
		t.Fatalf("expected active session effort 'high', got %q", app.ActiveSession.Effort)
	}
	if app.Chat.Effort != "high" {
		t.Fatalf("expected chat effort 'high', got %q", app.Chat.Effort)
	}
}
