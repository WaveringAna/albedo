// Keyboard selection, attachment, live tails, and delete confirmation require the TUI event loop.
package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/daemon"

	tea "charm.land/bubbletea/v2"

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

func TestAgentsViewSelectsAndAttaches(t *testing.T) {
	m := agentsFixture(t)
	if m.selected != "lead" {
		t.Fatalf("selected %q, want the active session", m.selected)
	}
	m.cycle(1)
	if m.selected == "lead" {
		t.Fatal("tab did not move the selection")
	}
	_, cmd := m.key(tea.KeyPressMsg{Code: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("enter on an empty input should attach")
	}
	if _, ok := cmd().(AgentsAttachMsg); !ok {
		t.Fatal("enter on an empty input should attach")
	}
}

// frames runs cmd and counts the frame ticks it schedules.
func frames(cmd tea.Cmd) int {
	if cmd == nil {
		return 0
	}
	switch msg := cmd().(type) {
	case tea.BatchMsg:
		n := 0
		for _, c := range msg {
			n += frames(c)
		}
		return n
	case agentsFrameMsg:
		return 1
	}
	return 0
}

func TestAgentsFramesStopWhenStillAndResumeOnce(t *testing.T) {
	m := agentsFixture(t)
	closed := make(chan []map[string]any)
	close(closed)
	m.events = closed
	running := func(id string, on bool) agentsEventsMsg {
		return agentsEventsMsg{Gen: 1, Events: []map[string]any{{"type": "running", "session": id, "running": on}}}
	}
	m, _ = m.Update(running("lead", false))
	m, _ = m.Update(running("coder", false))
	m, cmd := m.Update(agentsFrameMsg{Gen: 1})
	if n := frames(cmd); n != 0 {
		t.Fatalf("a still graph scheduled %d frames, want none", n)
	}
	m, cmd = m.Update(running("coder", true))
	if n := frames(cmd); n != 1 {
		t.Fatalf("a running agent scheduled %d frames, want one", n)
	}
	_, cmd = m.Update(running("lead", true))
	if n := frames(cmd); n != 0 {
		t.Fatalf("a second runner scheduled %d more frames, want none", n)
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
	_, cmd = chat.Update(tea.KeyPressMsg{Code: 'o', Mod: tea.ModCtrl})
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
		{"type": "arguments_delta", "session": "lead", "name": "python", "callId": "c1", "text": `{"code": "kid = await agents.self`},
		{"type": "arguments_delta", "session": "lead", "name": "python", "callId": "c1", "text": `.spawn(\"map\", name=\"scout\")\nprint(kid`},
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

// Partial JSON arguments arrive before a tool call finishes; a malformed escape must not hide streamed code.
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

func TestAgentsDeleteConfirmDropsWithTheAgent(t *testing.T) {
	m := agentsFixture(t)
	m.selected = "coder"
	m, _ = m.key(tea.KeyPressMsg{Code: 'x', Mod: tea.ModCtrl})
	if m.confirm != "coder" {
		t.Fatal("ctrl+x should ask before deleting coder")
	}
	m, _ = m.Update(agentsEventsMsg{Gen: 1, Events: []map[string]any{
		{"type": "gone", "session": "coder"},
	}})
	if m.confirm != "" {
		t.Fatalf("the confirm prompt outlived the agent it named:\n%s", ansi.Strip(m.View()))
	}
	if strings.Contains(ansi.Strip(m.View()), "delete coder") {
		t.Fatal("the view still offers to delete a vanished agent")
	}
	m.selected = "tests"
	m, _ = m.key(tea.KeyPressMsg{Code: 'x', Mod: tea.ModCtrl})
	if m.confirm != "tests" {
		t.Fatal("ctrl+x stopped working after the prompt was dropped")
	}
}

func TestAgentsDeleteAsksFirstAndSparesTheOpenSession(t *testing.T) {
	m := agentsFixture(t)
	m, _ = m.key(tea.KeyPressMsg{Code: 'x', Mod: tea.ModCtrl})
	if m.confirm != "" || !strings.Contains(ansi.Strip(m.View()), "session browser") {
		t.Fatal("the session the view opened from must not be deletable here")
	}
	m.selected = "coder"
	m, _ = m.key(tea.KeyPressMsg{Code: 'x', Mod: tea.ModCtrl})
	view := ansi.Strip(m.View())
	if m.confirm != "coder" || !strings.Contains(view, "delete coder and the agent below it?") {
		t.Fatalf("ctrl+x should ask first:\n%s", view)
	}
	m, cmd := m.key(tea.KeyPressMsg{Code: 'n', Text: "n"})
	if m.confirm != "" || cmd != nil {
		t.Fatal("any key but y keeps the agent")
	}
	m, _ = m.key(tea.KeyPressMsg{Code: 'x', Mod: tea.ModCtrl})
	_, cmd = m.key(tea.KeyPressMsg{Code: 'y', Text: "y"})
	if cmd == nil {
		t.Fatal("y should delete")
	}
}
