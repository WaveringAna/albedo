// Grapheme boundaries and terminal cell arithmetic are not visible through
// daemon E2E. Verify rendered output rather than the canvas representation.
package tui

import (
	"github.com/charmbracelet/x/ansi"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestAgentCanvasKeepsCellWidthWhenUnicodeLabelsAreOverwritten(t *testing.T) {
	canvas := newCanvas(16, 1)
	hue := rgb{}
	canvas.put(1, 0, "東京e\u0301👩‍💻", hue)
	line := ansi.Strip(canvas.line(0))
	if !strings.Contains(line, "東京e\u0301👩‍💻") || ansi.StringWidth(line) != 16 {
		t.Fatalf("Unicode label changed canvas width: %q", line)
	}
	// A graph edge landing in a wide glyph must clear the whole glyph.
	canvas.put(2, 0, "│", hue)
	canvas.put(15, 0, "界", hue)
	line = ansi.Strip(canvas.line(0))
	if ansi.StringWidth(line) != 16 || !utf8.ValidString(line) || strings.Contains(line, "東") || strings.Contains(line, "界") {
		t.Fatalf("overwriting or clipping a wide glyph corrupted the row: %q", line)
	}
}

func TestPythonBurstLabelTruncatesWholeUnicodeCharacters(t *testing.T) {
	code := strings.Repeat("#", 44) + "東京e\u0301界\nprint('done')"
	label := pyLabel(code)
	if !utf8.ValidString(label) || ansi.StringWidth(label) > 48 || !strings.HasSuffix(label, "…") {
		t.Fatalf("truncated label is not valid terminal text: %q", label)
	}
}
