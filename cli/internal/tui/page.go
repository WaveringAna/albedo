package tui

import (
	"slices"
	"strings"
	"sync/atomic"

	"github.com/charmbracelet/x/ansi"
)

// page is the state the list screens share: a cursor, the terminal size,
// the load or save in flight, and the last error and notice. Every request
// carries the Generation it was started under; a reply under any other is
// stale.
type page struct {
	Error, Notice                     string
	Cursor, Width, Height, Generation int
	Loading, Saving                   bool
}

// Commands outlive closed screens; unique generations reject their replies.
var pageGeneration atomic.Int64

func nextPageGeneration() int { return int(pageGeneration.Add(1)) }

func (p *page) SetSize(width, height int) { p.Width, p.Height = width, height }

// settle takes a reply for the request busy tracks: false when it is stale
// or failed, with the failure shown.
func (p *page) settle(gen int, err error, busy *bool) bool {
	if gen != p.Generation {
		return false
	}
	*busy = false
	if err != nil {
		p.Error = err.Error()
		return false
	}
	return true
}

// step moves the cursor for an arrow key over n items.
func (p *page) step(key string, n int) bool {
	switch key {
	case "up", "ctrl+p":
		p.Cursor = max(0, p.Cursor-1)
	case "down", "ctrl+n":
		p.Cursor = min(max(0, n-1), p.Cursor+1)
	default:
		return false
	}
	return true
}

// reselect keeps the cursor on the same item, by id, across a reload.
func reselect[T any](cursor int, before, after []T, id func(T) string) int {
	if cursor < len(before) {
		if i := slices.IndexFunc(after, func(item T) bool { return id(item) == id(before[cursor]) }); i >= 0 {
			return i
		}
	}
	return max(0, min(cursor, len(after)-1))
}

// header opens a page with its title rule, the last error and the notice.
func (p page) header(command, right string) []string {
	width := max(1, p.Width)
	rows := []string{titleRule(width, brand("albedo")+" "+DefaultStyles.Muted.Render(command), DefaultStyles.Faint.Render(right)), ""}
	if p.Error != "" {
		rows = append(rows, DefaultStyles.Error.Render(ansi.Truncate(p.Error, width, "…")))
	}
	if p.Notice != "" {
		rows = append(rows, DefaultStyles.Faint.Render(ansi.Truncate(p.Notice, width, "…")))
	}
	return rows
}

// listRow is one list entry, marked and highlighted under the cursor.
func listRow(selected bool, row string, width int) string {
	prefix := "  "
	if selected {
		prefix = selectBar() + " "
	}
	row = ansi.Truncate(prefix+row, width, "…")
	if selected {
		return selectedLine(row, width)
	}
	return row
}

// scrolled is the window of rows lines that keeps line at in view.
func scrolled(lines []string, at, rows int) []string {
	start := max(0, at-rows+1)
	return lines[start:min(len(lines), start+rows)]
}

// fit drops rows past the height, keeping the last one: the key hints.
func (p page) fit(rows []string) string {
	if p.Height > 0 && len(rows) > p.Height {
		rows = append(rows[:max(1, p.Height-1)], rows[len(rows)-1])
	}
	return strings.Join(rows, "\n")
}
