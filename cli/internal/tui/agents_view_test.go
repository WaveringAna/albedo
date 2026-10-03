// Invariants the e2e suite cannot reach, because each lives inside the
// tui package or needs a failure the daemon never produces:
//
//   - frame pacing: an idle graph must not keep scheduling animation frames,
//     a running one must resume them exactly once (wasted CPU, double speed);
//   - normalized replacement windows must survive interleaved calls without
//     settling another call's live preview into history;
//   - a pending delete confirm must not outlive the agent it names;
//   - a failed history seed must retry on the next selection, and a late
//     error from an older generation must not unseed the live node;
//   - overflow during a blocked mutation must preserve its later outcome and draft.
package tui

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/daemon"

	tea "charm.land/bubbletea/v2"

	"github.com/charmbracelet/x/ansi"
)

func agentsFixture(t *testing.T) AgentsViewModel {
	t.Helper()
	m := NewAgentsViewModel(nil, "lead")
	m.Gen = 1
	m.streamReady = true
	m.SetSize(120, 30)
	lead := "lead"
	coder := "coder"
	m, _ = m.Update(agentsSnapshotMsg{Gen: 1, Root: "lead", Nodes: []daemon.AgentNode{
		{Session: daemon.Session{ID: "lead", Title: "lead", Model: "gpt-6-luna"}, Name: "lead", Running: true},
		{Session: daemon.Session{ID: "scout", Model: "gpt-6-luna"}, Parent: &lead, Name: "scout", Depth: 1},
		{Session: daemon.Session{ID: "coder", Model: "gpt-6-luna"}, Parent: &lead, Name: "coder", Depth: 1, Running: true},
		{Session: daemon.Session{ID: "tests", Model: "gpt-6-luna"}, Parent: &coder, Name: "tests", Depth: 2},
	}})
	return m
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
	closed := make(chan tea.Msg)
	close(closed)
	m.events = closed
	running := func(id string, on bool) agentsEventsMsg {
		return agentsEventsMsg{Gen: 1, Events: []daemon.AgentEvent{{Type: "running", Session: id, Running: on}}}
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

func TestAgentsProgressResultKeepsOtherInterleavedCall(t *testing.T) {
	m := agentsFixture(t)
	m.selected = "coder"
	update := func(event daemon.AgentEvent) {
		m, _ = m.Update(agentsEventsMsg{Gen: 1, Events: []daemon.AgentEvent{event}})
	}
	callA := &daemon.ToolProgress{CallID: "run:1:0", ToolCallID: "native-a", Name: "python", Phase: "generating", Code: &daemon.ToolCodePreview{Text: "print('a')"}}
	callB := &daemon.ToolProgress{CallID: "run:1:1", ToolCallID: "native-b", Name: "python", Phase: "generating", Code: &daemon.ToolCodePreview{Text: "print('b')"}}
	update(daemon.AgentEvent{Type: "tool_progress", Session: "coder", Progress: callA})
	update(daemon.AgentEvent{Type: "tool_progress", Session: "coder", Progress: callB})
	update(daemon.AgentEvent{Type: "tool_progress", Session: "coder", Progress: &daemon.ToolProgress{
		CallID: callA.CallID, ToolCallID: callA.ToolCallID, Name: "python", Phase: "running",
	}})
	update(daemon.AgentEvent{Type: "tool_progress", Session: "coder", Progress: &daemon.ToolProgress{
		CallID: callB.CallID, ToolCallID: callB.ToolCallID, Name: "python", Phase: "generating", Code: &daemon.ToolCodePreview{Offset: 4, Text: "print('b2')"},
	}})
	update(daemon.AgentEvent{Type: "tool", Session: "coder", CallID: "native-a", ProgressCallID: callA.CallID, Name: "python", Output: "done"})
	got := ansi.Strip(m.View())
	if strings.Count(got, "print('b2')") != 1 || strings.Contains(got, "print('b')") || !strings.Contains(got, "done") {
		t.Fatalf("call A's result lost, appended, or duplicated call B's replacement window: %q", got)
	}
}

func TestAgentsDeleteConfirmDropsWithTheAgent(t *testing.T) {
	m := agentsFixture(t)
	m.selected = "coder"
	m, _ = m.key(tea.KeyPressMsg{Code: 'x', Mod: tea.ModCtrl})
	if m.confirm != "coder" {
		t.Fatal("ctrl+x should ask before deleting coder")
	}
	m, _ = m.Update(agentsEventsMsg{Gen: 1, Events: []daemon.AgentEvent{
		{Type: "gone", Session: "coder"},
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

// A seed that fails must not lock the node out of history: the next selection
// retries, and only the failure's own generation may unseed the node.
func TestFailedSeedRetriesOnTheNextSelection(t *testing.T) {
	var calls int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			http.Error(w, `{"error":"history is gone"}`, http.StatusInternalServerError)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"total": 2, "items": []map[string]string{
			{"type": "user", "preview": "fan out three scouts"},
			{"type": "assistant", "preview": "sent them off"},
		}})
	}))
	defer server.Close()
	address, _ := url.Parse(server.URL)
	port, _ := strconv.Atoi(address.Port())

	m := agentsFixture(t)
	m.Conn = daemon.NewConnection(daemon.ConnectionSnapshot{Port: port, Token: "t", Version: 2}, nil)
	m.selected = "coder"

	cmd := m.seedCmd()
	if cmd == nil {
		t.Fatal("an unseeded agent should ask for history")
	}
	msg := cmd()
	failure, ok := msg.(agentsSeedErrMsg)
	if !ok || failure.Err == nil {
		t.Fatalf("the failed request should report itself, got %T", msg)
	}
	m, _ = m.Update(failure)
	if m.nodes["coder"].seeded {
		t.Fatal("a failed seed left the node marked seeded")
	}
	if !strings.Contains(m.notice, failure.Err.Error()) {
		t.Fatalf("the notice should carry the failure, got %q", m.notice)
	}

	cmd = m.seedCmd()
	if cmd == nil {
		t.Fatal("the next selection should retry after a failed seed")
	}
	msg = cmd()
	seed, ok := msg.(agentsSeedMsg)
	if !ok {
		t.Fatalf("the retry should answer with history, got %T", msg)
	}
	m, _ = m.Update(seed)
	for _, want := range []string{"← fan out three scouts", "sent them off"} {
		if !strings.Contains(ansi.Strip(m.View()), want) {
			t.Fatalf("the retried seed should show %q in the tail:\n%s", want, ansi.Strip(m.View()))
		}
	}

	// An error from an earlier generation may not unseed the live node.
	m, _ = m.Update(agentsSeedErrMsg{Gen: m.Gen - 1, ID: "coder", Err: errors.New("late")})
	if !m.nodes["coder"].seeded {
		t.Fatal("a stale seed error unseeded the live node")
	}
	if cmd := m.seedCmd(); cmd != nil {
		t.Fatal("a seeded node should not fetch again")
	}
}

func TestAgentsOverflowPreservesPendingOperationOutcomeAndDraft(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			_, _ = w.Write([]byte(`{"ok":true,"version":2,"capabilities":["normalized_tool_progress"]}`))
			return
		}
		if r.URL.Path == "/agents/stream" {
			<-r.Context().Done()
			return
		}
		if r.URL.Path != "/sessions/lead/children" {
			t.Errorf("unexpected request: %s", r.URL.Path)
			w.WriteHeader(404)
			return
		}
		close(started)
		<-release
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"error":"spawn refused"}`))
	}))
	defer server.Close()
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
	}()
	address, _ := url.Parse(server.URL)
	port, _ := strconv.Atoi(address.Port())
	m := agentsFixture(t)
	m.Conn = daemon.NewConnection(daemon.ConnectionSnapshot{Port: port}, nil)
	for _, char := range "/spawn helper inspect files" {
		m, _ = m.Update(tea.KeyPressMsg{Code: char, Text: string(char)})
	}
	var cmd tea.Cmd
	m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	finished := make(chan tea.Msg, 1)
	go func() { finished <- cmd() }()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("spawn never reached server")
	}
	for _, char := range "next draft" {
		m, _ = m.Update(tea.KeyPressMsg{Code: char, Text: string(char)})
	}
	m, _ = m.Update(agentsEventsMsg{Gen: m.Gen, Events: []daemon.AgentEvent{{Type: "overflow"}}})
	defer func() { m.Close() }()
	close(release)
	select {
	case outcome := <-finished:
		m, _ = m.Update(outcome)
	case <-time.After(5 * time.Second):
		t.Fatal("spawn did not complete")
	}
	rendered := ansi.Strip(m.View())
	if !strings.Contains(rendered, "spawn refused") || !strings.Contains(rendered, "next draft") {
		t.Fatalf("overflow lost pending outcome or draft: %s", rendered)
	}
}

func TestAgentsTerminalEventsCannotReviveObsoleteCode(t *testing.T) {
	for _, kind := range []string{"error", "interrupted", "closed"} {
		t.Run(kind, func(t *testing.T) {
			m := agentsFixture(t)
			m.selected = "coder"
			update := func(events ...daemon.AgentEvent) {
				m, _ = m.Update(agentsEventsMsg{Gen: 1, Events: events})
			}
			update(daemon.AgentEvent{Type: "tool_progress", Session: "coder", Progress: &daemon.ToolProgress{CallID: "old", Name: "python", Phase: "generating", Code: &daemon.ToolCodePreview{Text: "obsolete_code_sentinel"}}})
			update(daemon.AgentEvent{Type: kind, Session: "coder", Text: "failed"})
			update(daemon.AgentEvent{Type: "tool_progress", Session: "coder", Progress: &daemon.ToolProgress{CallID: "fresh", Name: "python", Phase: "generating", Code: &daemon.ToolCodePreview{Text: "fresh_code_sentinel"}}})
			update(daemon.AgentEvent{Type: "tool", Session: "coder", ProgressCallID: "fresh", Name: "python", Output: "finished"})
			got := ansi.Strip(m.View())
			if strings.Count(got, "obsolete_code_sentinel") > 1 || !strings.Contains(got, "fresh_code_sentinel") || !strings.Contains(got, "finished") {
				t.Fatalf("%s revived obsolete code or lost the fresh result: %q", kind, got)
			}
		})
	}
}
