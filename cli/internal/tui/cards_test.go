// Verbose mode draws each call as a card the terminal client folds and
// unfolds on a click: the daemon e2e sees committed text, never these rows.
package tui

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	"github.com/charmbracelet/x/ansi"
)

func numbered(prefix string, n int) string {
	lines := make([]string, n)
	for i := range lines {
		lines[i] = fmt.Sprintf("%s %d", prefix, i+1)
	}
	return strings.Join(lines, "\n")
}

func pythonCall(code, output string, at int64) HistoryEntry {
	result, _ := json.Marshal(map[string]any{"status": "ok", "output": output, "duration": 1.5})
	return HistoryEntry{
		Kind: EntryTool, ToolName: "python", Timestamp: at,
		ToolArgs:   map[string]any{"code": code},
		ToolResult: string(result),
	}
}

func verboseChat(t *testing.T, height int, entries ...HistoryEntry) ChatModel {
	t.Helper()
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, height)
	m.Flags.Tools = true
	for _, entry := range entries {
		m.appendSettledEntry(entry)
	}
	m.refreshViewportContent()
	return m
}

// A long call shows the start of its code, its newest calls, and the start
// of its output, each behind a fold row; a click opens the whole card and
// "show less" closes it again.
func TestToolCardFoldsAndUnfoldsOnClick(t *testing.T) {
	call := pythonCall(numbered("step", 30), numbered("out", 40), 1000)
	call.ToolTrace = &daemon.ToolTrace{}
	for i := range 20 {
		call.ToolTrace.Activities = append(call.ToolTrace.Activities, daemon.ToolActivity{Kind: "run", Target: fmt.Sprintf("job %d", i+1)})
	}
	m := verboseChat(t, 200, call)
	screen := func() string { return ansi.Strip(m.Viewport.View()) }
	closed := screen()
	for _, want := range []string{"python", "1.5s", "step 10", "▸ 20 more lines", "▸ 12 more calls", "job 20", "out 5", "▸ 35 more lines"} {
		if !strings.Contains(closed, want) {
			t.Fatalf("closed card lacks %q:\n%s", want, closed)
		}
	}
	for _, hidden := range []string{"step 11", "job 12\n", "out 6"} {
		if strings.Contains(closed, hidden) {
			t.Fatalf("closed card shows %q:\n%s", hidden, closed)
		}
	}
	m.actAt(rowWith(t, m.frameLines, "▸ 35 more lines"))
	open := screen()
	for _, want := range []string{"step 30", "job 1", "out 40", "▾ show less"} {
		if !strings.Contains(open, want) {
			t.Fatalf("open card lacks %q:\n%s", want, open)
		}
	}
	m.actAt(rowWith(t, m.frameLines, "▾ show less"))
	if got := screen(); got != closed {
		t.Fatalf("closing did not restore the card:\n%s", got)
	}
}

// Opening a card keeps the rows around the clicked fold where they were on
// screen, though the sections above it open too.
func TestOpeningACardKeepsTheClickedRowOnScreen(t *testing.T) {
	var entries []HistoryEntry
	for i := range 6 {
		entries = append(entries, pythonCall(numbered("step", 30), numbered("out", 40), int64(i+1)))
	}
	m := verboseChat(t, 30, entries...)
	m.Follow = false
	m.scrollOffset = rowWith(t, m.frameLines, "▸ 35 more lines") - 5
	m.refreshViewportContent()
	m.actAt(m.scrollOffset + 5)
	view := strings.Split(ansi.Strip(m.Viewport.View()), "\n")
	if !strings.Contains(view[4], "out 5") || !strings.Contains(view[5], "out 6") {
		t.Fatalf("the opened card moved away from the click:\n%s", strings.Join(view, "\n"))
	}
}

// Tool output is untrusted text: colors and control characters are dropped
// and a card row never outgrows the transcript.
func TestToolCardContainsHostileOutput(t *testing.T) {
	m := verboseChat(t, 40, pythonCall("print(1)", "\x1b[31mred\x1b[0m\ttab\rcarriage "+strings.Repeat("w", 300), 1))
	for _, line := range strings.Split(m.Viewport.View(), "\n") {
		if w := ansi.StringWidth(line); w > 80 {
			t.Fatalf("a %d-cell row in an 80-cell transcript: %q", w, ansi.Strip(line))
		}
	}
	if screen := ansi.Strip(m.Viewport.View()); !strings.Contains(screen, "red    tab") {
		t.Fatalf("output was not cleaned:\n%s", screen)
	}
}
