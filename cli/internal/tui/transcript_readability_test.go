// Markdown table bounds and transcript copy selection are terminal-specific rendering rules.
package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	"github.com/charmbracelet/x/ansi"
)

func TestMarkdownTablesFitTranscript(t *testing.T) {
	text := "| Tool | Logged median | Warm in-kernel benchmark |\n" +
		"|:---|---:|---:|\n" +
		"| `files.read` | 3 ms | 0.07 ms |\n" +
		"| `files.paths` | too few isolated calls | 12.7 ms |"
	for _, width := range []int{38, 80} {
		got := RenderMarkdownAnsi(text, width)
		values := []string{"Tool", "files.read", "12.7 ms"}
		if width >= 80 {
			values = append(values, "files.paths")
		} else {
			values = append(values, "files.path")
		}
		for _, value := range values {
			if !strings.Contains(ansi.Strip(got), value) {
				t.Fatalf("width %d lost %q: %q", width, value, got)
			}
		}
		if strings.Contains(got, "|:---") {
			t.Fatalf("width %d exposed Markdown delimiter: %q", width, got)
		}
		for _, row := range strings.Split(got, "\n") {
			if ansi.StringWidth(row) > width {
				t.Fatalf("width %d produced %d-cell row: %q", width, ansi.StringWidth(row), row)
			}
		}
	}
}

func TestMarkdownTablesStayInsideMarkdownBlocks(t *testing.T) {
	text := "Intro\n\n| Name | Value |\n| --- | --- |\n| a\\|b | `x\\|y` |\n\n" +
		"```text\n| literal | row |\n| --- | --- |\n```\nOutro"
	got := ansi.Strip(RenderMarkdownAnsi(text, 72))
	for _, value := range []string{"Intro", "a|b", "x|y", "| literal | row |", "| --- | --- |", "Outro"} {
		if !strings.Contains(got, value) {
			t.Fatalf("missing %q from %q", value, got)
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
