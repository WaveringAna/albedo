// Inline math has to leave the dollar signs of prices and shell variables
// alone. Replies in e2e are scripted, so only this table pins which ones
// open math.
package tui

import "testing"

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
