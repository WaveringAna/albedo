package display

import (
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"strings"
)

// Line clips trusted, possibly application-styled text to display cells.
func Line(s string, width int) string {
	if width <= 0 {
		return ""
	}
	return ansi.Truncate(s, width, "…")
}

// Row spends width on identity before optional metadata. Its prefix has the
// same width in both states, so moving the cursor never shifts the label.
func Row(label, detail string, width int, current bool) string {
	if width <= 0 {
		return ""
	}
	prefix := "  "
	if current {
		prefix = "> "
	}
	if width <= 2 {
		return Line(prefix, width)
	}
	room := width - 2
	metadata := ""
	if width >= 48 && detail != "" {
		metadata = Line(SingleLine(detail), 18)
		room -= ansi.StringWidth(metadata) + 2
	}
	name := Line(SingleLine(label), room)
	body := prefix + name
	if metadata != "" {
		body += strings.Repeat(" ", max(0, room-ansi.StringWidth(name))) + "  " + metadata
	}
	return lipgloss.NewStyle().Bold(current).Render(body)
}

// Panel's argument is the OUTER width with zero margins. Padding and borders
// are already inside Width in Lip Gloss v2. No double frame subtraction.
func Panel(content string, outerWidth int) string {
	if outerWidth <= 0 {
		return ""
	}
	box := lipgloss.NewStyle().Border(lipgloss.NormalBorder()).Padding(0, 1)
	frame := box.GetHorizontalFrameSize()
	if outerWidth <= frame {
		return Line(strings.ReplaceAll(content, "\n", " "), outerWidth)
	}
	lines := strings.Split(content, "\n")
	for i := range lines {
		lines[i] = Line(lines[i], outerWidth-frame)
	}
	return box.Width(outerWidth).Render(strings.Join(lines, "\n"))
}

// FillRows fixes a one-line row region's height without rendering hidden items.
func FillRows(lines []string, width, height int) string {
	if height <= 0 || width <= 0 {
		return ""
	}
	out := make([]string, height)
	for i := 0; i < min(len(lines), height); i++ {
		out[i] = Line(lines[i], width)
	}
	return strings.Join(out, "\n")
}
