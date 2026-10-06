// Scrollback fetching must preserve position and resume after eviction in the TUI.
package tui

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// turn is one user message and its reply, committed as rows seq and seq+1.
func turn(name string, seq int64) []daemon.StreamEvent {
	return []daemon.StreamEvent{
		{Type: daemon.EventUser, Text: name, Source: "chat", Replayed: true},
		{Type: daemon.EventCommitted, Seq: seq, Replayed: true},
		{Type: daemon.EventMessage, Text: "reply to " + name + "\n" + strings.Repeat("more\n", 8), Replayed: true},
		{Type: daemon.EventCommitted, Seq: seq + 1, Replayed: true},
	}
}

func rowOf(view, text string) int {
	for i, line := range strings.Split(ansi.Strip(view), "\n") {
		if strings.Contains(line, text) {
			return i
		}
	}
	return -1
}

func TestScrollingToTheTopLoadsOlderHistoryInPlace(t *testing.T) {
	var asked []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		asked = append(asked, r.URL.RawQuery)
		_ = json.NewEncoder(w).Encode(map[string]any{"items": []any{protocolEntry("q", "user", "older question", 8), protocolEntry("a", "assistant", "older answer", 9)}, "older": nil, "newer": nil, "high_water": 9})
	}))
	defer server.Close()
	conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
	client := daemon.NewChatClient(conn, "s")
	m := NewChatModel(&daemon.Session{ID: "s"}, client)
	t.Cleanup(m.Close)
	m.SetSize(80, 20)
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventReset, Before: 10, More: true, Replayed: true})
	for i, name := range []string{"first", "second", "third"} {
		for _, evt := range turn(name, int64(10+2*i)) {
			m.handleStreamEvent(evt)
		}
	}
	m.refreshViewportContent()

	m.Follow = false
	m.scrollOffset = 1
	m.refreshViewportContent()
	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyUp})
	if cmd == nil || !m.loadingOlder {
		t.Fatal("reaching the top did not ask for older history")
	}
	before := rowOf(m.Viewport.View(), "first")
	if before < 0 {
		t.Fatal("the first turn is not on screen before loading")
	}
	m, _ = m.Update(cmd())
	if len(asked) != 1 || !strings.Contains(asked[0], "before=10") {
		t.Fatalf("asked %v", asked)
	}
	if got := rowOf(m.Viewport.View(), "first"); got != before {
		t.Fatalf("loading older history moved the view: row %d → %d", before, got)
	}
	entries := m.History.Entries()
	if entries[0].Text != "older question" || entries[0].Seq != 8 {
		t.Fatalf("older page not prepended: %+v", entries[0])
	}
	if _, more := m.olderCursor(); more {
		t.Fatal("history start not recorded")
	}
	m.scrollOffset = 0
	m.refreshViewportContent()
	if !strings.Contains(ansi.Strip(m.Viewport.View()), "older question") {
		t.Fatal("older page not shown above")
	}
	if _, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyUp}); cmd != nil {
		t.Fatal("asked again with nothing older")
	}
}

func TestEvictedHistoryResumesAfterItsNewestRow(t *testing.T) {
	h := NewBoundedHistory(3, 1<<20)
	for seq := int64(1); seq <= 3; seq++ {
		h.Append(HistoryEntry{Kind: EntryAssistant, Text: fmt.Sprint(seq)})
		h.Stamp(seq)
	}
	// Two entries from row 4: the first eviction takes row 1 only.
	h.Append(HistoryEntry{Kind: EntryThinking, Text: "4a"})
	h.Append(HistoryEntry{Kind: EntryAssistant, Text: "4b"})
	h.Stamp(4)
	if h.EvictedThrough() != 2 || h.Entries()[0].Text != "3" {
		t.Fatalf("evicted through %d, first %q", h.EvictedThrough(), h.Entries()[0].Text)
	}
	// Evicting into row 4 takes both of its entries.
	h.Append(HistoryEntry{Kind: EntryAssistant, Text: "5"})
	h.Append(HistoryEntry{Kind: EntryAssistant, Text: "6"})
	if h.EvictedThrough() != 4 || h.Entries()[0].Text != "5" {
		t.Fatalf("row 4 split: evicted through %d, first %q", h.EvictedThrough(), h.Entries()[0].Text)
	}
	h.Prepend([]HistoryEntry{{Kind: EntryUser, Text: "old", Seq: 4}})
	if h.EvictedThrough() != 0 || h.Entries()[0].Text != "old" {
		t.Fatal("prepend did not take over the cursor")
	}
}

func TestOlderPagesReuseBlocksExactlyAsAFreshRebuildDrawsThem(t *testing.T) {
	// Kept blocks are an invariant across every kind of entry and burst
	// boundary; an e2e sees only the screen, not which rows were reused.
	page := func(from int) []daemon.StreamEvent {
		var events []daemon.StreamEvent
		for i := from; i < from+6; i++ {
			id := fmt.Sprint(i)
			at := int64(1_000_000 + i*60_000)
			events = append(events,
				daemon.StreamEvent{Type: daemon.EventUser, EntryID: "u" + id, Position: int64(i), Text: "ask " + id, Timestamp: &at},
				daemon.StreamEvent{Type: daemon.EventThinking, EntryID: "k" + id, Position: int64(i), Text: "think " + id},
				daemon.StreamEvent{Type: daemon.EventTool, EntryID: "t" + id, Position: int64(i), ToolName: "python", ToolArgs: map[string]any{"code": "print(" + id + ")"}, ToolResult: id},
				daemon.StreamEvent{Type: daemon.EventMessage, EntryID: "a" + id, Position: int64(i), Text: "**answer** " + id, Timestamp: &at},
				daemon.StreamEvent{Type: daemon.EventTurnCompleted, Source: "done"},
			)
		}
		return events
	}
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(100, 30)
	for _, event := range page(100) {
		m.handleStreamEvent(event)
	}
	for from := 94; from >= 70; from -= 6 {
		m.Follow, m.scrollOffset, m.loadingOlder = false, 0, true
		m = m.showOlder(ChatOlderLoadedMsg{SessionID: m.SessionID, Generation: m.Generation, Page: &daemon.HistoryPage{Events: page(from), Before: int64(from), More: true}})
		reused := slices.Clone(m.settledLines)
		m.settled = nil
		m.rebuildSettledLines()
		if !slices.Equal(reused, m.settledLines) {
			t.Fatalf("after the page from %d, reused rows differ from a fresh rebuild", from)
		}
	}
}
