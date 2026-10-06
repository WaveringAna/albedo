package tui

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/charmbracelet/x/ansi"
)

// chipRows is the height of the strip of cards above the composer: the
// thumbnail area and a border above and below it.
const chipRows = thumbRows + 2

// chip is one card of the strip: a title naming its marker, up to thumbRows
// lines of content, and a caption.
type chip struct {
	title, caption string
	content        []string
}

// chips are the attachments the composer still marks, in reading order.
func (m ChatModel) chips() []chip {
	var chips []chip
	seen := make(map[string]bool)
	for _, match := range anyMarker.FindAllString(m.TextArea.Value(), -1) {
		if seen[match] {
			continue
		}
		seen[match] = true
		if found := imageMarker.FindStringSubmatch(match); found != nil {
			n, _ := strconv.Atoi(found[1])
			if image, ok := m.Images.byNumber[n]; ok {
				chips = append(chips, m.imageChip(n, image))
			}
		} else if found := pasteMarker.FindStringSubmatch(match); found != nil {
			n, _ := strconv.Atoi(found[1])
			if text, ok := m.Pastes.byNumber[n]; ok {
				chips = append(chips, m.pasteChip(n, text))
			}
		}
	}
	return chips
}

func (m ChatModel) imageChip(n int, image pastedImage) chip {
	content := []string{"", DefaultStyles.Faint.Render("image")}
	if image.thumb != nil {
		content = placeholderRows(*image.thumb)
	}
	return chip{
		title:   "image #" + strconv.Itoa(n),
		caption: fmt.Sprintf("%d×%d", image.Width, image.Height),
		content: content,
	}
}

func (m ChatModel) pasteChip(n int, text string) chip {
	lines := strings.Split(text, "\n")
	caption := "+" + strconv.Itoa(len(lines)) + " lines"
	if len(lines) <= collapseLines {
		caption = strconv.Itoa(len([]rune(text))) + " chars"
	}
	content := make([]string, 0, thumbRows)
	for _, line := range lines[:min(len(lines), thumbRows)] {
		line = ansi.Truncate(strings.ReplaceAll(line, "\t", "  "), thumbCols, "")
		// padded to the full width, so the card keeps the lines left-aligned
		content = append(content, DefaultStyles.Faint.Render(line+strings.Repeat(" ", thumbCols-ansi.StringWidth(line))))
	}
	return chip{title: "paste #" + strconv.Itoa(n), caption: caption, content: content}
}

// chipStrip lays the chips out side by side within width, chipRows rows
// high, or returns nil when there are none. Cards that do not fit are
// counted at the end instead.
func (m ChatModel) chipStrip(width int) []string {
	chips := m.chips()
	if len(chips) == 0 {
		return nil
	}
	const cardWidth = thumbCols + 2
	shown := min(len(chips), (width+1)/(cardWidth+1))
	if shown < len(chips) && shown*(cardWidth+1)+len("+99") > width {
		shown-- // room for the count of the rest
	}
	rows := make([]string, chipRows)
	for i, c := range chips[:max(0, shown)] {
		for r, line := range m.card(c) {
			rows[r] += strings.Repeat(" ", min(i, 1)) + line
		}
	}
	if hidden := len(chips) - max(0, shown); hidden > 0 {
		rows[chipRows/2] += DefaultStyles.Faint.Render(" +" + strconv.Itoa(hidden))
	}
	return rows
}

// card draws c in a rounded border thumbCols+2 cells wide, its content
// centred, its title on the top edge and its caption on the bottom one.
func (m ChatModel) card(c chip) []string {
	edge := func(left, label, right string) string {
		label = ansi.Truncate(label, thumbCols-2, "…")
		fill := thumbCols - ansi.StringWidth(label) - 2
		return DefaultStyles.Decor.Render(left+strings.Repeat("─", fill-fill/2)+" ") +
			DefaultStyles.Muted.Render(label) +
			DefaultStyles.Decor.Render(" "+strings.Repeat("─", fill/2)+right)
	}
	side := DefaultStyles.Decor.Render("│")
	rows := []string{edge("╭", c.title, "╮")}
	top := (thumbRows - len(c.content)) / 2
	for r := range thumbRows {
		line := ""
		if r >= top && r-top < len(c.content) {
			line = c.content[r-top]
		}
		pad := thumbCols - ansi.StringWidth(line)
		rows = append(rows, side+strings.Repeat(" ", pad/2)+line+strings.Repeat(" ", pad-pad/2)+side)
	}
	return append(rows, edge("╰", c.caption, "╯"))
}
