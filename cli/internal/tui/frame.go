package tui

import (
	"cmp"
	"strings"

	"github.com/charmbracelet/x/ansi"
)

// listFrame is the layout every list screen shares: the title rule, an optional
// filter, the list beside the highlighted row's detail pane when there is
// room, and the footer, all clipped to the terminal once. A screen supplies
// the parts and none of the arithmetic.
type listFrame struct {
	title, right string // the title rule's two ends, styled
	filter       string // the search line as drawn; empty for a screen without one
	list         func(width, height int) []string
	// pane is the detail beside the list; nil for a list alone.
	pane func(width, height int) []string
	// paneWidth is the pane's width at a terminal width; nil is sidePane.
	paneWidth func(width int) int
	// summary is the detail's one-line stand-in when the pane has no room.
	summary string
	// footer is the finished bottom rows: hints, status, or a confirmation.
	footer string
}

// Side by side needs this much terminal.
const (
	paneMinWidth  = 96
	paneMinHeight = 14
)

// sidePane is a narrow detail column for facts about the highlighted row.
func sidePane(width int) int { return min(max(width/3, 34), 48) }

// halfPane is half the terminal, for previews that read like text.
func halfPane(width int) int { return width - width/2 - ansi.StringWidth(svSep()) }

// view draws the frame at exactly the terminal's size or less; an unsized
// terminal is 80 by 24.
func (f listFrame) view(width, height int) string {
	width, height = cmp.Or(width, 80), cmp.Or(height, 24)
	roomy := height >= 12

	lines := []string{" " + titleRule(width-1, f.title, f.right)}
	if roomy {
		lines = append(lines, "")
	}
	if f.filter != "" {
		lines = append(lines, " "+f.filter)
		if height >= 9 {
			lines = append(lines, "")
		}
	}

	paned := f.pane != nil && width >= paneMinWidth && height >= paneMinHeight
	var tail []string
	if roomy {
		tail = append(tail, "")
	}
	if !paned && f.summary != "" && height >= 16 {
		tail = append(tail, " "+f.summary)
	}
	tail = append(tail, strings.Split(f.footer, "\n")...)
	body := max(1, height-len(lines)-len(tail))

	if paned {
		paneW := sidePane(width)
		if f.paneWidth != nil {
			paneW = f.paneWidth(width)
		}
		list := f.list(width-paneW-ansi.StringWidth(svSep()), body)
		pane := f.pane(paneW, body)
		for i := range body {
			lines = append(lines, list[i]+svSep()+pane[i])
		}
	} else {
		lines = append(lines, f.list(width, body)...)
	}
	lines = append(lines, tail...)

	if len(lines) > height {
		lines = append(lines[:max(0, height-1)], lines[len(lines)-1])
	}
	for i, line := range lines {
		lines[i] = ansi.Truncate(line, width, "…")
	}
	return strings.Join(lines, "\n")
}

// footerLine is the keys on the left and a status on the right. When both
// do not fit the keys give way to an urgent status (an error, work in
// flight) and the status to the keys otherwise.
func footerLine(width int, hints []hint, status string, urgent bool) string {
	if len(hints) == 0 {
		return " " + status
	}
	room := width - 1
	if status != "" {
		room = width - ansi.StringWidth(status) - 3
	}
	left := fitHints(hints, room)
	switch {
	case left == "" && urgent && status != "":
		return " " + status
	case left == "":
		return " " + ansi.Truncate(keyHints(hints...), max(1, width-2), "…")
	case status == "":
		return left
	}
	return left + strings.Repeat(" ", width-ansi.StringWidth(left)-ansi.StringWidth(status)-1) + status
}
