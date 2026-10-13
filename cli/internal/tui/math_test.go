// Inline math has to leave the dollar signs of prices and shell variables
// alone, and display math has to stay inside the list item it belongs to.
// Replies in e2e are scripted and never look at layout, so only these pin it.
package tui

import (
	"regexp"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func TestScanInlineMath(t *testing.T) {
	for _, tc := range []struct {
		line   string
		before rune
		tex    string
		length int
	}{
		{line: "$E = mc^2$ holds", before: ' ', tex: "E = mc^2", length: 10},
		{line: `\(\alpha\) and`, before: ' ', tex: `\alpha`, length: 10},
		{line: "$$x$$ inline", before: ' ', tex: "x", length: 5},
		{line: `$a \$ b$`, before: ' ', tex: `a \$ b`, length: 8},
		{line: "$5 or $10", before: ' '},
		{line: "$HOME/$USER", before: ' '},
		{line: "$FOO$BAR", before: ' '},
		{line: "$x$", before: 'a'},
		{line: "$ x$", before: ' '},
		{line: "$x $", before: ' '},
		{line: "$x\n$", before: ' '},
		{line: "$$", before: ' '},
	} {
		tex, length := scanInlineMath([]byte(tc.line), tc.before)
		if tex != tc.tex || length != tc.length {
			t.Errorf("%q after %q: got %q, %d; want %q, %d", tc.line, tc.before, tex, length, tc.tex, tc.length)
		}
	}
}

func TestDisplayMathHangsInsideListItems(t *testing.T) {
	rendered := ansi.Strip(RenderMarkdownAnsi("- item\n\n  $$\\frac{a}{b}$$\n- next", 40))
	want := "• item\n\n   a\n  ───\n   b\n• next"
	if got := trailingSpace.ReplaceAllString(rendered, ""); got != want {
		t.Errorf("rendered\n%s\nwant\n%s", got, want)
	}
}

var trailingSpace = regexp.MustCompile(`(?m) +$`)
