// Effort selector focus, cancellation, and narrow-terminal navigation need keyboard events.
package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestEffortSelectorStaysInChatAndCommits(t *testing.T) {
	session := daemon.Session{ID: "s1", Model: "model", Effort: "high"}
	app := NewAppModel(nil, config.Profiles{}, &session, "/work", false)
	app.Chat.SetSize(80, 22)
	updated, _ := app.Update(commandExecutedMsg{Name: "/effort", Available: []string{"low", "medium", "high", "xhigh", "max"}, Gen: app.CommandGen})
	app = updated.(AppModel)
	view := ansi.Strip(app.View().Content)
	if app.State != AppStateChat || app.Chat.effortSelected != 2 || !strings.Contains(view, "[high]") {
		t.Fatal("expected current tier selected within chat")
	}
	lines := strings.Split(view, "\n")
	found := false
	for i := 1; i+1 < len(lines); i++ {
		if strings.TrimSpace(lines[i]) == "Reasoning effort" && strings.TrimSpace(lines[i-1]) == "" && strings.Contains(lines[i+1], "[high]") {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected a spaced title and separate tiers, got:\n%s", view)
	}
	if strings.Contains(view, "ctrl+g editor") {
		t.Fatal("composer must be hidden while choosing effort")
	}
	oldHeight := app.Chat.Viewport.Height()
	updated, _ = app.Update(tea.KeyPressMsg{Code: tea.KeyRight})
	app = updated.(AppModel)
	if app.Chat.effortSelected != 3 || !strings.Contains(ansi.Strip(app.View().Content), "[xhigh]") {
		t.Fatal("right did not select xhigh")
	}
	updated, cmd := app.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	app = updated.(AppModel)
	if len(app.Chat.effortOptions) != 0 || app.Chat.Viewport.Height() != oldHeight+3 {
		t.Fatal("selector did not close and restore viewport")
	}
	got, ok := cmd().(ChatExecuteCommandMsg)
	if !ok || got.Name != "/effort" || got.Args != "xhigh" {
		t.Fatalf("unexpected selection: %#v", got)
	}
}

func TestEffortSelectorEscapeAndNarrowLayout(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s1", Effort: "max"}, nil)
	m.SetSize(28, 15)
	m.openEffortSelector([]string{"low", "medium", "high", "xhigh", "max"})
	if line := m.effortSelectorView(); !strings.Contains(ansi.Strip(line), "[max]") || ansi.StringWidth(line) > m.chatWidth() {
		t.Fatalf("selected level clipped or line too wide: %q", line)
	}
	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	if cmd != nil || len(m.effortOptions) != 0 {
		t.Fatal("escape did not dismiss selector")
	}
	if len(m.History.Entries()) != 0 {
		t.Fatal("selector should not write to history")
	}
}
