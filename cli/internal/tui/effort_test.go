package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
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

func TestDisplayPreferencesFollowChatsAndRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "picker.json")
	first := daemon.Session{ID: "first"}
	app := NewAppModel(nil, config.Profiles{}, &first, "/work", false)
	app.LoadPrefs(path)
	for _, command := range []string{"/t", "/v"} {
		app.Chat.TextArea.SetValue(command)
		updated, _ := app.Update(tea.KeyMsg{Type: tea.KeyEnter})
		app = updated.(AppModel)
	}
	if !app.Chat.Flags.Thinking || !app.Chat.Flags.Tools {
		t.Fatal("toggles did not apply")
	}
	if saved := loadSessionPrefs(path); !saved.Thinking || !saved.Tools {
		t.Fatalf("not saved: %+v", saved)
	}
	second := daemon.Session{ID: "second"}
	chat := app.newChatModel(&second)
	if !chat.Flags.Thinking || !chat.Flags.Tools {
		t.Fatal("new chat reset display choices")
	}
	restarted := NewAppModel(nil, config.Profiles{}, &second, "/work", false)
	restarted.LoadPrefs(path)
	if !restarted.Chat.Flags.Thinking || !restarted.Chat.Flags.Tools {
		t.Fatal("restart reset display choices")
	}
	restarted.Chat.TextArea.SetValue("/t")
	updated, _ := restarted.Update(tea.KeyMsg{Type: tea.KeyEnter})
	restarted = updated.(AppModel)
	if !restarted.Chat.Flags.Tools || restarted.Chat.Flags.Thinking {
		t.Fatal("thinking toggle also reset verbose")
	}
	if saved := loadSessionPrefs(path); saved.Thinking || !saved.Tools {
		t.Fatalf("off state not saved: %+v", saved)
	}
}
