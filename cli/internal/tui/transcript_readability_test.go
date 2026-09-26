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

func TestMarkdownCodeBlocksUseChromaAndThemeInk(t *testing.T) {
	one := ink{code: "#ddddee", secondary: "#778899", brandFrom: "#77aadd", brandTo: "#ddaacc"}
	two := ink{code: "#dddddd", secondary: "#778899", brandFrom: "#77aadd", brandTo: "#ddaacc"}
	if codeTheme(one) == codeTheme(two) {
		t.Fatal("theme change reused the old syntax palette")
	}
	before := transcriptInk
	transcriptInk = one
	defer func() { transcriptInk = before }()
	got := RenderMarkdownAnsi("```go\n// note\nfunc main() { println(42) }\n```", 80)
	if !strings.Contains(ansi.Strip(got), "func main()") || !strings.Contains(got, "\x1b[") {
		t.Fatalf("code was not syntax highlighted: %q", got)
	}
}

func TestMarkdownPreservesTranscriptLineBreaks(t *testing.T) {
	got := ansi.Strip(RenderMarkdownAnsi(strings.Repeat("settled\n", 25), 80))
	if strings.Count(got, "\n") < 24 {
		t.Fatalf("collapsed streamed lines: %q", got)
	}
}

func TestMarkdownComposition(t *testing.T) {
	text := "> This is a blockquote.\n\n```js\nconst greeting = \"Hello, Markdown!\";\nconsole.log(greeting);\n```\n\n---\n\nThat's the end."
	got := RenderMarkdownAnsi(text, 80)
	plain := ansi.Strip(got)
	for _, part := range []string{"│ This is a blockquote.", "┌─", "const greeting", "└", "────────────", "That's the end."} {
		if !strings.Contains(plain, part) {
			t.Fatalf("missing %q from %q", part, plain)
		}
	}
	if !strings.Contains(got, decorInk()+"┌─") || strings.Contains(plain, "--------") {
		t.Fatalf("code and divider are not using the transcript's decor ink: %q", got)
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
			if got := SelectedText(lines, row); got != "bash" {
				t.Fatalf("copied the tool row as %q", got)
			}
		}
	}
}

// Rows that spell no unwrapped line, like a table's, stay rows of their own.
func TestMarkWrapsLeavesTablesAlone(t *testing.T) {
	text := "| a | b |\n|---|---|\n| 1 | a long cell that has plenty of words in it to wrap |"
	if got := renderCopyable(text, 40); strings.Contains(got, markWrap) || strings.Contains(got, markSplit) {
		t.Fatalf("joined table rows: %q", got)
	}
}
