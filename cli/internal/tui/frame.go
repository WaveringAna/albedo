package tui

import (
	"cmp"
	"slices"
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
	// summary is the detail's one-line stand-in when the pane has no room at all.
	summary string
	// footer is the finished bottom rows: hints, status, or a confirmation.
	footer string
}

// Side by side needs this much terminal; a narrower one with this many body
// rows stacks the pane under the list instead.
const (
	paneMinWidth  = 96
	paneMinHeight = 14
	stackMinBody  = 12
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
	tail = append(tail, strings.Split(f.footer, "\n")...)
	body := max(1, height-len(lines)-len(tail))
	stacked := !paned && f.pane != nil && body >= stackMinBody
	if !paned && !stacked && f.summary != "" && height >= 16 {
		tail = slices.Insert(tail, len(tail)-strings.Count(f.footer, "\n")-1, " "+f.summary)
		body = max(1, height-len(lines)-len(tail))
	}

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
	} else if stacked {
		paneH := body / 2
		lines = append(lines, f.list(width, body-paneH-1)...)
		lines = append(lines, " "+DefaultStyles.Decor.Render(strings.Repeat("─", max(0, width-2))))
		for _, line := range f.pane(width-1, paneH) {
			lines = append(lines, " "+line)
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
// do not fit, an urgent status (an error, a notice, work in flight) takes
// a row of its own above the keys, and any other status gives way to them.
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
	case left != "" && status != "":
		return left + strings.Repeat(" ", width-ansi.StringWidth(left)-ansi.StringWidth(status)-1) + status
	case left != "":
		return left
	}
	keys := fitHints(hints, width-1)
	if keys == "" {
		keys = " " + ansi.Truncate(keyHints(hints...), max(1, width-2), "…")
	}
	if urgent && status != "" {
		return " " + ansi.Truncate(status, max(1, width-2), "…") + "\n" + keys
	}
	return keys
}
