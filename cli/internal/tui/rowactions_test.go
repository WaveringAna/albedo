// Clickable rows and selections that scroll are drawn and
// driven in the terminal client: the daemon e2e sees committed text, never
// rendered rows or mouse events, so these regressions are invisible outside
// the TUI.
package tui

import (
	"fmt"
	"slices"
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// Dragging past the top edge scrolls the transcript and keeps selecting, so
// the copy reaches rows that were never on screen together.
func TestDraggingPastTheEdgeScrollsAndKeepsSelecting(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 20)
	for i := range 40 {
		m.appendSettledEntry(HistoryEntry{Kind: EntryNote, Text: fmt.Sprintf("note %02d", i), Timestamp: int64(i + 1)})
	}
	m.refreshViewportContent()
	if !m.Follow || m.scrollLimit == 0 {
		t.Fatalf("fixture does not overflow: follow %v limit %d", m.Follow, m.scrollLimit)
	}
	first := 2 + m.Notices.ChromeRows()
	at := func(row int) tea.Mouse { return tea.Mouse{X: 10, Y: first + row, Button: tea.MouseLeft} }
	m, _ = m.Update(tea.MouseClickMsg(at(m.Viewport.Height() - 2)))
	m, cmd := m.Update(tea.MouseMotionMsg(at(0)))
	if cmd == nil || m.dragDir != -1 {
		t.Fatalf("the top edge does not start a scroll: dir %d", m.dragDir)
	}
	start := m.scrollOffset
	for range 5 {
		m, cmd = m.Update(dragScrollMsg{gen: m.dragGen})
	}
	if m.scrollOffset != start-5 || m.dragHead.Row != m.scrollOffset || cmd == nil {
		t.Fatalf("scrolled %d -> %d, head row %d", start, m.scrollOffset, m.dragHead.Row)
	}
	sel := Selection{Anchor: *m.dragAnchor, Head: m.dragHead, Gutter: railWidth}
	text := SelectedText(m.frameLines, sel)
	offscreen := strings.TrimSpace(ansi.Strip(m.frameLines[start-2]))
	if !strings.HasPrefix(offscreen, "note") || !strings.Contains(text, offscreen) {
		t.Fatalf("the copy stops at the screen, missing %q:\n%s", offscreen, text)
	}

	m, _ = m.Update(tea.MouseMotionMsg(at(m.Viewport.Height() / 2)))
	if m.dragDir != 0 {
		t.Fatalf("leaving the edge keeps scrolling: dir %d", m.dragDir)
	}
}

// The signoff copies the whole turn's prose as markdown, and the cells page lists every
// call with the one under the cursor in full.
func rowWith(t *testing.T, lines []string, text string) int {
	t.Helper()
	for i, line := range lines {
		if strings.Contains(ansi.Strip(line), text) {
			return i
		}
	}
	t.Fatalf("no row says %q", text)
	return -1
}

func TestSignoffCopiesTheTurnAsMarkdown(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 40)
	m.appendSettledEntry(HistoryEntry{Kind: EntryUser, Text: "hi", Timestamp: 1})
	m.appendSettledEntry(HistoryEntry{Kind: EntryAssistant, Text: "# first\n\n```go\nx := 1\n```", Timestamp: 2})
	m.appendSettledEntry(HistoryEntry{Kind: EntryTool, ToolName: "bash", Timestamp: 3})
	m.appendSettledEntry(HistoryEntry{Kind: EntryAssistant, Text: "**second**", Timestamp: 4})
	m.appendSettledEntry(HistoryEntry{Kind: EntryTurnEnd, Mood: moodDone, Timestamp: 5})
	m.refreshViewportContent()
	row := rowWith(t, m.frameLines, "⧉")
	act, _ := actionOf(m.frameLines[row])
	if cmd := m.actAt(row); cmd == nil || m.CopyStatus != "copied" {
		t.Fatalf("the signoff did not copy: status %q", m.CopyStatus)
	}
	if got, _ := m.replyMarkdown(act.key); got != "# first\n\n```go\nx := 1\n```\n\n**second**" {
		t.Fatalf("the signoff copied %q", got)
	}
}

// Clicking a burst's summary lists every step in full, the commands the
// summary only names included, and clicking it again folds them away.
func TestClickingABurstListsItsSteps(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s", Workspace: "/w/albedo"})
	m.SetSize(120, 40)
	m.appendSettledEntry(HistoryEntry{Kind: EntryUser, Text: "go", Timestamp: 1})
	for _, entry := range burstFixture() {
		m.appendSettledEntry(entry)
	}
	m.appendSettledEntry(HistoryEntry{Kind: EntryAssistant, Text: "done", Timestamp: 9})
	m.refreshViewportContent()
	full := "cd cli && go test ./..."
	row := rowWith(t, m.frameLines, "▸ thought")
	if text := ansi.Strip(strings.Join(m.frameLines, "\n")); strings.Contains(text, full) {
		t.Fatalf("a closed burst lists its steps:\n%s", text)
	}
	m.actAt(row)
	spliced := slices.Clone(m.settledLines)
	if m.rebuildSettledLines(); !slices.Equal(spliced, m.settledLines) {
		t.Fatal("opening the burst drew rows a rebuild does not")
	}
	m.refreshViewportContent()
	text := ansi.Strip(strings.Join(m.frameLines, "\n"))
	for _, step := range []string{"▾ thought", "run    " + full, "read   cli/internal/tui/chat.go", "edit   priv/python/albedo_trace.py", "python · 1/0"} {
		if !strings.Contains(text, step) {
			t.Fatalf("the open burst does not show %q:\n%s", step, text)
		}
	}
	m.actAt(rowWith(t, m.frameLines, "▾ thought"))
	if text := ansi.Strip(strings.Join(m.frameLines, "\n")); strings.Contains(text, full) || !strings.Contains(text, "▸ thought") {
		t.Fatalf("a second click does not close the burst:\n%s", text)
	}
}

// A long message of yours shows its first rows and a click target; clicking
// it shows the rest, and the row that closes it folds the message again.
func TestClickingALongMessageShowsTheRestAndFoldsIt(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(100, 30)
	var lines []string
	for i := range 40 {
		lines = append(lines, fmt.Sprintf("line %02d", i))
	}
	m.appendSettledEntry(HistoryEntry{Kind: EntryUser, Text: strings.Join(lines, "\n\n"), Timestamp: 1})
	m.appendSettledEntry(HistoryEntry{Kind: EntryAssistant, Text: "done", Timestamp: 2})
	m.refreshViewportContent()
	shown := func() string { return ansi.Strip(strings.Join(m.frameLines, "\n")) }
	if text := shown(); strings.Contains(text, "line 39") || !strings.Contains(text, "more lines · click to expand") {
		t.Fatalf("a long message is not folded:\n%s", text)
	}
	spliced := func() {
		t.Helper()
		got := slices.Clone(m.settledLines)
		if m.rebuildSettledLines(); !slices.Equal(got, m.settledLines) {
			t.Fatal("the splice drew rows a rebuild does not")
		}
		m.refreshViewportContent()
	}
	click := rowWith(t, m.frameLines, "click to expand")
	m.actAt(click)
	spliced()
	if text := shown(); !strings.Contains(text, "line 39") || !strings.Contains(text, "show less") {
		t.Fatalf("clicking does not show the rest:\n%s", text)
	}
	m.actAt(rowWith(t, m.frameLines, "show less"))
	spliced()
	if text := shown(); strings.Contains(text, "line 39") || !strings.Contains(text, "click to expand") {
		t.Fatalf("clicking again does not fold the message:\n%s", text)
	}
}
