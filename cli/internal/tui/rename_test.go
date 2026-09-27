// Rename keyboard actions must target only the selected session or agent.
package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/daemon"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func keysOf(s string) []tea.KeyPressMsg {
	var keys []tea.KeyPressMsg
	for _, r := range s {
		keys = append(keys, tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	return keys
}

var (
	ctrlR     = tea.KeyPressMsg{Code: 'r', Mod: tea.ModCtrl}
	enterKey  = tea.KeyPressMsg{Code: tea.KeyEnter}
	escKey    = tea.KeyPressMsg{Code: tea.KeyEscape}
	backspace = tea.KeyPressMsg{Code: tea.KeyBackspace}
)

func renameRequest(t *testing.T, cmd tea.Cmd) SessionRenameMsg {
	t.Helper()
	if cmd == nil {
		t.Fatal("expected a rename request")
	}
	msg, ok := cmd().(SessionRenameMsg)
	if !ok {
		t.Fatalf("expected a rename request, got %T", cmd())
	}
	return msg
}

func TestSessionViewerRenamesInPlace(t *testing.T) {
	m := NewSessionViewer("/work")
	m.SetSize(100, 20)
	m.SetSessions([]daemon.Session{{ID: "one", Title: "fix the login bug"}, {ID: "two", Title: "new session"}}, nil)
	m.focus("one")

	m, _ = m.Update(ctrlR)
	if !m.rename.active() || m.rename.input.Value() != "fix the login bug" {
		t.Fatalf("ctrl+r should open the title for editing: %+v", m.rename)
	}
	// Keys that search, move, or pin elsewhere are text while renaming.
	for range len("login bug") {
		m, _ = m.Update(backspace)
	}
	for _, k := range keysOf("jq") {
		m, _ = m.Update(k)
	}
	if m.SearchInput.Value() != "" || m.rename.input.Value() != "fix the jq" {
		t.Fatalf("typing leaked: search %q draft %q", m.SearchInput.Value(), m.rename.input.Value())
	}
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "✎  fix the jq") || !strings.Contains(view, "enter save") {
		t.Fatalf("the row should become the field:\n%s", view)
	}
	m, cmd := m.Update(enterKey)
	if got := renameRequest(t, cmd); got != (SessionRenameMsg{ID: "one", Name: "fix the jq"}) {
		t.Fatalf("request %+v", got)
	}
	if m.rename.active() {
		t.Fatal("enter should close the field")
	}
	m.Renamed(daemon.Session{ID: "one", Title: "fix the jq"})
	if item, _ := m.Highlighted(); item.ID != "one" || item.Label != "fix the jq" {
		t.Fatalf("renamed row lost focus or label: %+v", item)
	}

	// An untitled session starts from an empty draft; esc discards it and an
	// unchanged name saves nothing.
	m.focus("two")
	m, _ = m.Update(ctrlR)
	if m.rename.input.Value() != "" {
		t.Fatalf("untitled draft %q", m.rename.input.Value())
	}
	m, _ = m.Update(keysOf("x")[0])
	m, cmd = m.Update(escKey)
	if cmd != nil || m.rename.active() || m.ArchiveView {
		t.Fatal("esc should only close the field")
	}
	m, _ = m.Update(ctrlR)
	if _, cmd = m.Update(enterKey); cmd != nil {
		t.Fatal("an unchanged name should not be saved")
	}
}

// A title taken from a message can fill the whole limit, so typing first
// replaces the opening draft rather than being refused past it.
func TestRenameTypingReplacesTheOpeningDraft(t *testing.T) {
	long := strings.Repeat("x", renameLimit-1)
	m := NewSessionViewer("/work")
	m.SetSize(100, 20)
	m.SetSessions([]daemon.Session{{ID: "one", Title: long}}, nil)
	m.focus("one")
	m, _ = m.Update(ctrlR)
	for _, k := range keysOf("short") {
		m, _ = m.Update(k)
	}
	m, cmd := m.Update(enterKey)
	if got := renameRequest(t, cmd); got != (SessionRenameMsg{ID: "one", Name: "short"}) {
		t.Fatalf("request %+v", got)
	}
}

func TestSessionViewerDoesNotRenameActions(t *testing.T) {
	m := NewSessionViewer("/work")
	m.SetSize(100, 20)
	m.SetSessions(nil, nil)
	m.focus("new")
	if m, _ = m.Update(ctrlR); m.rename.active() {
		t.Fatal("New session is not a session to rename")
	}
}

func TestAgentsViewRenamesTheSelectedAgent(t *testing.T) {
	m := agentsFixture(t)
	coder := "coder"
	m.nodes["coder"].address = coder
	m.selected = "coder"
	m, _ = m.key(ctrlR)
	if m.rename.id != "coder" || m.rename.input.Value() != "coder" {
		t.Fatalf("ctrl+r should open the agent's name: %+v", m.rename)
	}
	for range 5 {
		m, _ = m.key(backspace)
	}
	for _, k := range keysOf("builder") {
		m, _ = m.key(k)
	}
	view := ansi.Strip(m.View())
	for _, want := range []string{"✎ builder", "rename coder", "still mails it as coder", "empty restores coder"} {
		if !strings.Contains(view, want) {
			t.Errorf("view is missing %q:\n%s", want, view)
		}
	}
	if m.input.Value() != "" {
		t.Fatal("the name went to the message input")
	}
	m, cmd := m.key(enterKey)
	if got := renameRequest(t, cmd); got != (SessionRenameMsg{ID: "coder", Name: "builder"}) {
		t.Fatalf("request %+v", got)
	}
	m, _ = m.Update(agentsEventsMsg{Gen: 1, Events: []map[string]any{{"type": "renamed", "session": "coder", "name": "builder"}}})
	if m.nodes["coder"].name != "builder" {
		t.Fatal("the stream's rename should relabel the dot")
	}

	m.selected = agentsYou
	if m, _ = m.key(ctrlR); m.rename.active() {
		t.Fatal("you are not an agent to rename")
	}
}
