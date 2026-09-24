package tui

import (
	"strings"

	"github.com/charmbracelet/x/ansi"
	"github.com/rivo/uniseg"
)

type Point struct {
	Row int
	Col int
}
type Selection struct {
	Anchor Point
	Head   Point
	// Gutter is the decoration at the start of every row, which neither
	// the highlight nor the copied text includes.
	Gutter int
}

func (s Selection) IsEmpty() bool { return s.Anchor == s.Head }
func (s Selection) Normalized() (Point, Point) {
	if s.Anchor.Row < s.Head.Row || (s.Anchor.Row == s.Head.Row && s.Anchor.Col <= s.Head.Col) {
		return s.Anchor, s.Head
	}
	return s.Head, s.Anchor
}

func selectedRange(line string, from, to int) (plain string, before string, selected string, after string) {
	plain = ansi.Strip(line)
	var chosen, prefix, suffix strings.Builder
	col := 0
	for len(plain) > 0 {
		cluster, rest, _, _ := uniseg.FirstGraphemeClusterInString(plain, -1)
		width := ansi.StringWidth(cluster)
		switch {
		case col+width > from && col < to:
			chosen.WriteString(cluster)
		case col < from:
			prefix.WriteString(cluster)
		default:
			suffix.WriteString(cluster)
		}
		plain = rest
		col += width
	}
	return ansi.Strip(line), prefix.String(), chosen.String(), suffix.String()
}

func SelectedText(lines []string, sel Selection) string {
	if sel.IsEmpty() || len(lines) == 0 {
		return ""
	}
	start, end := sel.Normalized()
	if start.Row >= len(lines) {
		return ""
	}
	var rows []string
	for row := max(0, start.Row); row <= end.Row && row < len(lines); row++ {
		from, to := sel.Gutter, ansi.StringWidth(lines[row])
		if row == start.Row {
			from = max(from, start.Col)
		}
		if row == end.Row {
			to = end.Col
		}
		_, _, text, _ := selectedRange(lines[row], from, to)
		rows = append(rows, text)
	}
	return strings.Join(rows, "\n")
}

func HighlightSelection(lines []string, sel Selection) []string {
	if sel.IsEmpty() {
		return lines
	}
	start, end := sel.Normalized()
	out := append([]string(nil), lines...)
	for row := max(0, start.Row); row <= end.Row && row < len(out); row++ {
		from, to := sel.Gutter, ansi.StringWidth(out[row])
		if row == start.Row {
			from = max(from, start.Col)
		}
		if row == end.Row {
			to = end.Col
		}
		_, before, text, after := selectedRange(out[row], from, to)
		if text != "" {
			out[row] = before + DefaultStyles.Cursor.Render(text) + after
		}
	}
	return out
}
