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
		{"type": "progress", "session": "lead", "text": "three scouts out"},
		{"type": "closed", "session": "scout"},
	}})
	for range 8 {
		m.step()
	}
	view := ansi.Strip(m.View())
	t.Log("\n" + view)
	for _, want := range []string{"lead", "scout", "coder", "tests", "docs", "▸ python", "spawning the scouts", "← coder result", "» three scouts out", "✓ scout", "/agents"} {
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

func TestAgentsTailStreamsCodeThinkingAndOutput(t *testing.T) {
	m := agentsFixture(t)
	events := []map[string]any{
		{"type": "thinking", "session": "lead", "text": "the scouts need a brief"},
		{"type": "arguments_delta", "session": "lead", "callId": "c1", "text": `{"code": "kid = await agents.self`},
		{"type": "arguments_delta", "session": "lead", "callId": "c1", "text": `.spawn(\"map\", name=\"scout\")\nprint(kid`},
	}
	m, _ = m.Update(agentsEventsMsg{Gen: 1, Events: events})
	live := ansi.Strip(m.View())
	for _, want := range []string{"the scouts need a brief", "│ kid = await agents.self", `name="scout")`, "│ print(kid", "● live"} {
		if !strings.Contains(live, want) {
			t.Errorf("mid-stream view is missing %q\n%s", want, live)
		}
	}
	m, _ = m.Update(agentsEventsMsg{Gen: 1, Events: []map[string]any{
		{"type": "tool_progress", "session": "lead", "progress": map[string]any{"name": "python", "phase": "running"}},
		{"type": "tool", "session": "lead", "name": "python", "output": "scout\nspawned"},
	}})
	done := ansi.Strip(m.View())
	for _, want := range []string{"│ print(kid", "▸ python", "⎿ scout", "⎿ spawned"} {
		if !strings.Contains(done, want) {
			t.Errorf("settled view is missing %q\n%s", want, done)
		}
	}
}

func TestAgentsTailStartsFromHistory(t *testing.T) {
	m := agentsFixture(t)
	seed := agentsSeedMsg{Gen: 1, ID: "lead"}
	seed.Items = append(seed.Items, struct {
		Type    string `json:"type"`
		Preview string `json:"preview"`
	}{"user", "fan out three scouts"}, struct {
		Type    string `json:"type"`
		Preview string `json:"preview"`
	}{"assistant", "sent them off"})
	m, _ = m.Update(seed)
	view := ansi.Strip(m.View())
	for _, want := range []string{"← fan out three scouts", "sent them off"} {
		if !strings.Contains(view, want) {
			t.Errorf("seeded tail is missing %q", want)
		}
	}
}

func TestCodeLinesReadsPartialJSON(t *testing.T) {
	got := codeLines(`{"code": "a = 1\nb = \"x\"\nprint(a`)
	want := []string{"a = 1", `b = "x"`, "print(a"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("codeLines = %q, want %q", got, want)
	}
	if got := codeLines(`{"code": "done\n", "timeout_ms": 5}`); strings.Join(got, "|") != "done" {
		t.Fatalf("a closed string stops at its quote, got %q", got)
	}
}

func TestAgentsDeleteAsksFirstAndSparesTheOpenSession(t *testing.T) {
	m := agentsFixture(t)
	m, _ = m.key(tea.KeyMsg{Type: tea.KeyCtrlX})
	if m.confirm != "" || !strings.Contains(ansi.Strip(m.View()), "session browser") {
		t.Fatal("the session the view opened from must not be deletable here")
	}
	m.selected = "coder"
	m, _ = m.key(tea.KeyMsg{Type: tea.KeyCtrlX})
	view := ansi.Strip(m.View())
	if m.confirm != "coder" || !strings.Contains(view, "delete coder and the agent below it?") {
		t.Fatalf("ctrl+x should ask first:\n%s", view)
	}
	m, cmd := m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("n")})
	if m.confirm != "" || cmd != nil {
		t.Fatal("any key but y keeps the agent")
	}
	m, _ = m.key(tea.KeyMsg{Type: tea.KeyCtrlX})
	_, cmd = m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("y")})
	if cmd == nil {
		t.Fatal("y should delete")
	}
}
