package tui

import (
	"strings"
	"testing"

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
