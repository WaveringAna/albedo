package tui

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func TestInlineSpansRestateEnclosingEmphasis(t *testing.T) {
	got := inline("**a `b` c**", emphasis{})
	after := got[strings.LastIndex(got, "`")+1:]
	if !strings.HasPrefix(after, emphasis{strong: true}.sgr()) {
		t.Fatalf("closing code span dropped the enclosing bold: %q", got)
	}
	if got := ansi.Strip(inline("2 * 3 * 4 and `a*b*c`", emphasis{})); got != "2 * 3 * 4 and `a*b*c`" {
		t.Fatalf("spaced or code asterisks became emphasis: %q", got)
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
