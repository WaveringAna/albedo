package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/daemon"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/charmbracelet/x/ansi"
)

func agentsFixture(t *testing.T) AgentsViewModel {
	t.Helper()
	m := NewAgentsViewModel(nil, "lead")
	m.Gen = 1
	m.SetSize(120, 30)
	lead := "lead"
	coder := "coder"
	m, _ = m.Update(agentsSnapshotMsg{Gen: 1, Root: "lead", Nodes: []agentWire{
		{Session: daemon.Session{ID: "lead", Title: "lead", Model: "gpt-6-luna"}, Name: "lead", Running: true},
		{Session: daemon.Session{ID: "scout", Model: "gpt-6-luna"}, Parent: &lead, Name: "scout", Depth: 1},
		{Session: daemon.Session{ID: "coder", Model: "gpt-6-luna"}, Parent: &lead, Name: "coder", Depth: 1, Running: true},
		{Session: daemon.Session{ID: "tests", Model: "gpt-6-luna"}, Parent: &coder, Name: "tests", Depth: 2},
	}})
	return m
}

func TestAgentsViewDrawsTheTreeAndTail(t *testing.T) {
	m := agentsFixture(t)
	m, _ = m.Update(agentsEventsMsg{Gen: 1, Events: []map[string]any{
		{"type": "text", "session": "lead", "text": "spawning the scouts\nwaiting on"},
		{"type": "tool_progress", "session": "lead", "progress": map[string]any{"name": "python", "phase": "running"}},
		{"type": "mail", "id": "m1", "from": "coder", "fromName": "coder", "to": "lead", "kind": "result", "bytes": 4000.0},
		{"type": "spawn", "session": "docs", "parent": "coder", "name": "docs", "depth": 2.0, "model": "gpt-6-luna"},
	}})
	for range 8 {
		m.step()
	}
	view := ansi.Strip(m.View())
	t.Log("\n" + view)
	for _, want := range []string{"lead", "scout", "coder", "tests", "docs", "▸ python", "spawning the scouts", "← coder result", "/agents"} {
		if !strings.Contains(view, want) {
			t.Errorf("view is missing %q", want)
		}
	}
	if len(m.packets) != 1 {
		t.Errorf("mail should travel as one packet, got %d", len(m.packets))
	}
}

func TestAgentsViewSelectsAndAttaches(t *testing.T) {
	m := agentsFixture(t)
	if m.selected != "lead" {
		t.Fatalf("selected %q, want the active session", m.selected)
	}
	m.cycle(1)
	if m.selected == "lead" {
		t.Fatal("tab did not move the selection")
	}
	_, cmd := m.key(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("enter on an empty input should attach")
	}
	if _, ok := cmd().(AgentsAttachMsg); !ok {
		t.Fatal("enter on an empty input should attach")
	}
}

func TestAgentsViewSizesBeforeItOpens(t *testing.T) {
	var m AgentsViewModel
	m.SetSize(120, 30)
	if m.View() == "" {
		t.Log("an unopened view renders nothing, as expected")
	}
}

func TestAgentsOpenFromTheCommandAndCtrlO(t *testing.T) {
	m := AppModel{State: AppStateChat, ActiveSession: &daemon.Session{ID: "lead"}}
	_, cmd := m.Update(ChatExecuteCommandMsg{Name: "/agents"})
	if cmd == nil {
		t.Fatal("/agents did nothing")
	}
	if _, ok := cmd().(ChatOpenAgentsMsg); !ok {
		t.Fatal("/agents should open the agents view, not the session browser")
	}
	chat := NewChatModel(&daemon.Session{ID: "lead"}, nil)
	_, cmd = chat.Update(tea.KeyMsg{Type: tea.KeyCtrlO})
	if cmd == nil {
		t.Fatal("ctrl+o did nothing")
	}
	if _, ok := cmd().(ChatOpenAgentsMsg); !ok {
		t.Fatal("ctrl+o should open the agents view")
	}
}
