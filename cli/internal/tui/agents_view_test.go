// Four invariants the e2e suite cannot reach, because each lives inside the
// tui package or needs a failure the daemon never produces:
//
//   - frame pacing: an idle graph must not keep scheduling animation frames,
//     a running one must resume them exactly once (wasted CPU, double speed);
//   - the preview decoder must reveal streamed code from incomplete JSON arguments,
//     which a real stream only ever shows mid-flight;
//   - a pending delete confirm must not outlive the agent it names;
//   - a failed history seed must retry on the next selection, and a late
//     error from an older generation must not unseed the live node.
package tui

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strconv"
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

// Tool previews must expose code before the argument JSON is complete.
func TestAgentsPreviewReadsPartialJSON(t *testing.T) {
	var preview agentPreview
	preview.appendArguments(`{"code": "a = 1\nb = \"x\"\nprint(a`)
	var got []string
	for line := range preview.lines.newest(true) {
		got = append(got, line.text)
	}
	slices.Reverse(got)
	want := []string{"a = 1", `b = "x"`, "print(a"}
	if !slices.Equal(got, want) {
		t.Fatalf("preview = %q, want %q", got, want)
	}
	preview = agentPreview{}
	preview.appendArguments(`{"code": "done\n", "timeout_ms": 5}`)
	lines := slices.Collect(preview.lines.newest(true))
	if len(lines) != 1 || lines[0].text != "done" {
		t.Fatalf("a closed string stops at its quote, got %q", lines)
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
		_ = json.NewEncoder(w).Encode(map[string]any{"items": []map[string]string{
			{"type": "user", "preview": "fan out three scouts"},
			{"type": "assistant", "preview": "sent them off"},
		}})
	}))
	defer server.Close()
	address, _ := url.Parse(server.URL)
	port, _ := strconv.Atoi(address.Port())

	m := agentsFixture(t)
	m.Conn = daemon.NewConnection(daemon.ConnectionSnapshot{Port: port, Token: "t", Version: 2}, "")
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
