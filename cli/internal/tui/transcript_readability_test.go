// Markdown table bounds and transcript copy selection live in the terminal
// rendering path: the daemon e2e sees only committed text, never rendered
// rows, and no harness can drive a mouse selection, so these regressions are
// invisible outside the TUI.
package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	"github.com/charmbracelet/x/ansi"
)

const tableTranscript = "| Tool | Logged median | Warm in-kernel benchmark |\n" +
	"|:---|---:|---:|\n" +
	"| `files.read` | 3 ms | 0.07 ms |\n" +
	"| `files.paths` | too few isolated calls | 12.7 ms |"

// Tables render inside the transcript's width: every cell that fits survives,
// a narrow table truncates its columns rather than its rows or its syntax,
// and escaped pipes and fenced literal tables are never parsed as tables.
func TestMarkdownTablesRenderWithinTheirBounds(t *testing.T) {
	for _, tc := range []struct {
		name   string
		text   string
		width  int
		want   []string
		absent string
	}{
		{"keeps every column it fits", tableTranscript, 80,
			[]string{"Tool", "files.read", "files.paths", "12.7 ms"}, "|:---"},
		{"narrow truncates columns, not rows or the syntax", tableTranscript, 38,
			[]string{"Tool", "files.read", "files.path", "12.7 ms"}, "|:---"},
		{"escaped pipes and fenced rows stay literal",
			"Intro\n\n| Name | Value |\n| --- | --- |\n| a\\|b | `x\\|y` |\n\n" +
				"```text\n| literal | row |\n| --- | --- |\n```\nOutro",
			72,
			[]string{"Intro", "a|b", "x|y", "| literal | row |", "| --- | --- |", "Outro"}, ""},
	} {
		got := ansi.Strip(RenderMarkdownAnsi(tc.text, tc.width))
		for _, value := range tc.want {
			if !strings.Contains(got, value) {
				t.Fatalf("%s: width %d lost %q:\n%s", tc.name, tc.width, value, got)
			}
		}
		if tc.absent != "" && strings.Contains(got, tc.absent) {
			t.Fatalf("%s: width %d exposed %q:\n%s", tc.name, tc.width, tc.absent, got)
		}
		for _, row := range strings.Split(got, "\n") {
			if w := ansi.StringWidth(row); w > tc.width {
				t.Fatalf("%s: width %d produced a %d-cell row: %q", tc.name, tc.width, w, row)
			}
		}
	}
}

func TestSelectionSkipsTheRail(t *testing.T) {
	lines := []string{"│ you", "│ can you list the tools", "", "│ albedo"}
	sel := Selection{Anchor: Point{Row: 0, Col: 0}, Head: Point{Row: 3, Col: 8}, Gutter: railWidth}
	if got, want := SelectedText(lines, sel), "you\ncan you list the tools\n\nalbedo"; got != want {
		t.Fatalf("copied %q, want %q", got, want)
	}
	for _, row := range HighlightSelection(lines, sel) {
		if strings.HasPrefix(row, "\x1b[7m") {
			t.Fatalf("highlight covers the rail: %q", row)
		}
	}
}

// A copy is the text: no padding out to the viewport's width or height, no
// chrome, no code block frame or quote bars, and wrapped rows joined back
// into their lines.
func TestSelectionCopiesOnlyText(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s"}, nil)
	m.SetSize(60, 70)
	m.appendSettledEntry(HistoryEntry{Kind: EntryUser, Text: "why does the thing break when i do the other thing, it is really annoying"})
	m.appendSettledEntry(HistoryEntry{Kind: EntryTool, ToolName: "bash"})
	m.appendSettledEntry(HistoryEntry{Kind: EntryAssistant, Text: "a paragraph that is long enough that it will **definitely** wrap around the width.\n" +
		"hard break\n\nsee https://example.com/a/really/long/path/without/any/spaces/in/it/at/all\n\n" +
		"- an item that also goes on for a while so it wraps onto a second row\n\n" +
		"```go\nfmt.Println(\"a line of code that is longer than the width of the chat\")\n```\n\n" +
		"> quoted text that goes on long enough to wrap around the width\n> > twice\n\n" +
		"done."})
	m.appendSettledEntry(HistoryEntry{Kind: EntryTurnEnd, Mood: moodDone, ElapsedMs: 5000, Tools: 1})
	m.refreshViewportContent()
	lines := strings.Split(m.Viewport.View(), "\n")
	all := Selection{Anchor: Point{Row: 0, Col: 0}, Head: Point{Row: len(lines) - 1, Col: 60}, Gutter: railWidth}
	want := "why does the thing break when i do the other thing, it is really annoying\n\n" +
		"a paragraph that is long enough that it will definitely wrap around the width.\n" +
		"hard break\n\nsee https://example.com/a/really/long/path/without/any/spaces/in/it/at/all\n\n" +
		"• an item that also goes on for a while so it wraps onto a second row\n\n" +
		"fmt.Println(\"a line of code that is longer than the width of the chat\")\n\n" +
		"quoted text that goes on long enough to wrap around the width\n\ntwice\n\n" +
		"done."
	if got := SelectedText(lines, all); got != want {
		t.Fatalf("copied %q, want %q", got, want)
	}
	// chrome copies when it is all you selected
	for i, line := range lines {
		if strings.Contains(ansi.Strip(line), "bash") {
			row := Selection{Anchor: Point{Row: i, Col: 0}, Head: Point{Row: i, Col: 60}, Gutter: railWidth}
			if got := SelectedText(lines, row); got != "ran bash" {
				t.Fatalf("copied the tool row as %q", got)
			}
		}
	}
}
