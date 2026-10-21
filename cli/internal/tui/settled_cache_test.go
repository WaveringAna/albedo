// Rendered rows must not depend on what the markdown piece cache happens to
// hold: the cache is a memo, and any future change to what it keeps (a window,
// a budget, an eviction) must not move a byte on screen. A rebuild with the
// cache empty is the path a scroll back up or a resize takes.
package tui

import (
	"fmt"
	"slices"
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
)

// settledCacheEntries is a transcript of prose, code, tool rows and signoffs,
// long enough to trim rows past the caps.
func settledCacheEntries(count int) []HistoryEntry {
	var entries []HistoryEntry
	for i := range count {
		entries = append(entries,
			HistoryEntry{
				ID: fmt.Sprintf("u%d", i), Kind: EntryUser, Source: "chat", Speaker: "You", Timestamp: int64(i) * 1000,
				Text: fmt.Sprintf("question %d: does the cache change what this row says?\n\nA paragraph that wraps at the body width, with `inline code` in it, so the render is not one line.", i),
			},
			HistoryEntry{
				ID: fmt.Sprintf("a%d", i), Kind: EntryAssistant, Speaker: "albedo", Timestamp: int64(i)*1000 + 1,
				Text: fmt.Sprintf("### answer %d\n\nThe block below is the one that costs, and it is the same block every time:\n\n```go\nfunc answer%d(rows []string) int {\n\treturn len(rows)\n}\n```\n\n- a list item that wraps at the body width, long enough to be worth measuring\n- another one\n", i, i),
			},
			HistoryEntry{
				ID: fmt.Sprintf("t%d", i), Kind: EntryTool, ToolName: "run", Timestamp: int64(i)*1000 + 2,
				ToolArgs:   map[string]any{"code": "print(1)"},
				ToolResult: strings.Repeat("line of output\n", 4),
				ToolTrace: &daemon.ToolTrace{Activities: []daemon.ToolActivity{
					{Kind: "run", Target: "go -C cli test ./internal/tui"},
					{Kind: "read", Target: "/w/chat_history.go"},
				}},
			},
			HistoryEntry{ID: fmt.Sprintf("e%d", i), Kind: EntryTurnEnd, Mood: moodDone, ElapsedMs: 1200, Timestamp: int64(i)*1000 + 3},
		)
	}
	return entries
}

// settledAt settles entries the way a stream does, one appended at a time, so
// rows are trimmed against the caps as they arrive.
func settledAt(t *testing.T, entries []HistoryEntry, width int) *ChatModel {
	t.Helper()
	m := newTestChatModel(t, &daemon.Session{ID: "s", Workspace: "/w"})
	m.SetSize(width, 40)
	for _, entry := range entries {
		m.appendSettledEntry(entry)
	}
	return &m
}

// TestSettledRowsSurviveAColdCache rebuilds the transcript with the markdown
// cache intact and with it emptied, at two body widths, and requires the same
// rows, the same spans, and the same count of rows dropped above them.
func TestSettledRowsSurviveAColdCache(t *testing.T) {
	entries := settledCacheEntries(150)
	t.Cleanup(clearPieces)
	for _, width := range []int{80, 120} {
		t.Run(fmt.Sprintf("%d-cols", width), func(t *testing.T) {
			m := settledAt(t, entries, width)
			m.rebuildSettledLines()
			if m.droppedSettledLines == 0 {
				t.Fatalf("test transcript settled %d rows without trimming any", len(m.settledLines))
			}
			rows, spans, dropped := slices.Clone(m.settledLines), slices.Clone(m.settledSpans), m.droppedSettledLines

			clearPieces()
			m.rebuildSettledLines()
			if !slices.Equal(rows, m.settledLines) {
				t.Fatalf("a cold cache drew %d rows where the warm one drew %d: %s",
					len(m.settledLines), len(rows),
					firstDifference(strings.Join(rows, "\n"), strings.Join(m.settledLines, "\n")))
			}
			if !slices.Equal(spans, m.settledSpans) || dropped != m.droppedSettledLines {
				t.Fatalf("a cold cache changed the spans (%d vs %d) or the rows dropped (%d vs %d)",
					len(m.settledSpans), len(spans), m.droppedSettledLines, dropped)
			}
		})
	}
}
