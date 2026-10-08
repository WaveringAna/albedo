package tui

import (
	"math"
	"slices"
	"strings"

	"github.com/charmbracelet/x/ansi"
	"github.com/rivo/uniseg"
)

// Row marks are zero-width APC strings that widths and ansi.Strip skip.
// They tell a copy what a row is beyond its text. AppModel.View removes them
// before Bubble Tea renders; they must never reach the terminal.
const (
	// markChrome labels the transcript rather than being part of it: who
	// speaks, a turn's signoff, tool glances.
	markChrome = "\x1b_albedo:chrome\x1b\\"
	// markWrap continues the row above, which broke at a space, and
	// markSplit continues it mid-word.
	markWrap  = "\x1b_albedo:wrap\x1b\\"
	markSplit = "\x1b_albedo:split\x1b\\"
)

// chrome marks every row of s.
func chrome(s string) string {
	return markChrome + strings.ReplaceAll(s, "\n", "\n"+markChrome)
}

// wrapJoiner is what goes between a row and the row above it continues.
func wrapJoiner(line string) (string, bool) {
	if strings.Contains(line, markWrap) {
		return " ", true
	}
	return "", strings.Contains(line, markSplit)
}

// markChunks marks the rows line wrapped into as continuing the one before,
// and gives them the line's chrome.
func markChunks(line string, chunks []string) []string {
	carried := ""
	if strings.Contains(line, markChrome) {
		carried = markChrome
	}
	for i := 1; i < len(chunks); i++ {
		mark := markSplit
		if strings.HasSuffix(ansi.Strip(chunks[i-1]), " ") {
			mark = markWrap
		}
		chunks[i] = carried + mark + chunks[i]
	}
	return chunks
}

// markWraps marks the rows of wrapped, markdown rendered to a width, that
// continue the row above. flat is the same markdown unwrapped: a run of
// wrapped rows that spells one of its lines, in order, is that line. A row
// that spells none, like a table's, stays a line of its own.
func markWraps(wrapped, flat string) string {
	rows := strings.Split(wrapped, "\n")
	var lines []string
	for line := range strings.SplitSeq(flat, "\n") {
		lines = append(lines, rowText(line))
	}
	// rest is what the line being spelled has left, after a space when spaced
	next, rest, spaced := 0, "", false
	for i, row := range rows {
		text := rowText(row)
		if cont := strings.TrimLeft(text, " "); rest != "" && cont != "" && strings.HasPrefix(rest, cont) {
			mark := markSplit
			if spaced {
				mark = markWrap
			}
			rows[i] = mark + row
			rest, spaced = spell(rest, cont)
			continue
		}
		rest = ""
		// rows that spell nothing hold the search back, so it looks ahead
		// past the flat lines they stand for
		for k := next; k < min(len(lines), next+16); k++ {
			if lines[k] == text || text != "" && strings.HasPrefix(lines[k], text) {
				next = k + 1
				rest, spaced = spell(lines[k], text)
				break
			}
		}
	}
	return strings.Join(rows, "\n")
}

// spell is what line has left after text, and whether spaces came first.
func spell(line, text string) (string, bool) {
	after := line[len(text):]
	rest := strings.TrimLeft(after, " ")
	return rest, len(rest) < len(after)
}

// rowText is what a row says: its plain text without quote bars or padding.
func rowText(line string) string {
	_, text, _ := selectedRange(line, 0, math.MaxInt, quoteColumns(line))
	return strings.TrimRight(text, " ")
}

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

// selectedRange splits line around the columns from to to. Columns in skip
// are left out of the selection.
func selectedRange(line string, from, to int, skip map[int]bool) (before, selected, after string) {
	plain := ansi.Strip(line)
	var chosen, prefix, suffix strings.Builder
	col := 0
	for len(plain) > 0 {
		cluster, rest, _, _ := uniseg.FirstGraphemeClusterInString(plain, -1)
		width := ansi.StringWidth(cluster)
		switch {
		case col+width > from && col < to:
			if !skip[col] {
				chosen.WriteString(cluster)
			}
		case col < from:
			prefix.WriteString(cluster)
		default:
			suffix.WriteString(cluster)
		}
		plain = rest
		col += width
	}
	return prefix.String(), chosen.String(), suffix.String()
}

// selBounds is the column range of sel on one row of lines.
func selBounds(line string, sel Selection, start, end Point, row int) (int, int) {
	from, to := sel.Gutter, ansi.StringWidth(line)
	if row == start.Row {
		from = max(from, start.Col)
	}
	if row == end.Row {
		to = end.Col
	}
	return from, to
}

// SelectedText is the text under sel: what the rows say, without what the
// transcript draws around it. Code block frames and quote bars are left out,
// and so are chrome rows unless nothing else is selected; wrapped rows join
// back into their lines.
func SelectedText(lines []string, sel Selection) string {
	if sel.IsEmpty() || len(lines) == 0 {
		return ""
	}
	start, end := sel.Normalized()
	type piece struct {
		text          string
		joiner        string
		chrome, joins bool
	}
	var picked []piece
	onlyChrome := true
	for row := max(0, start.Row); row <= end.Row && row < len(lines); row++ {
		line := lines[row]
		if strings.Contains(line, codeFence(fenceOpen)) {
			continue
		}
		// a code block's closing frame also spaces the block from what
		// follows, so it copies as a blank row
		if strings.Contains(line, codeFence(fenceClose)) {
			picked = append(picked, piece{})
			continue
		}
		from, to := selBounds(line, sel, start, end, row)
		_, text, _ := selectedRange(line, from, to, quoteColumns(line))
		if act, ok := actionOf(line); ok && act.verb == verbOpen {
			// the toggle is a control, not part of what the row says
			text = strings.TrimPrefix(strings.TrimPrefix(text, toggleClosed), toggleOpen)
		}
		// rows are padded out to the viewport's width
		p := piece{text: strings.TrimRight(text, " "), chrome: strings.Contains(line, markChrome)}
		if row > start.Row {
			p.joiner, p.joins = wrapJoiner(line)
		}
		onlyChrome = onlyChrome && (p.chrome || p.text == "")
		picked = append(picked, p)
	}
	var rows []string
	// joinable says the last row kept is the row above; dropped says chrome
	// was left out since the last text, so a blank row after it is spare
	joinable, dropped := false, false
	for _, p := range picked {
		switch {
		case p.chrome && !onlyChrome:
			joinable, dropped = false, true
		case p.joins && joinable:
			rows[len(rows)-1] += p.joiner + strings.TrimLeft(p.text, " ")
		case p.text == "" && dropped && len(rows) > 0 && rows[len(rows)-1] == "":
			joinable = false
		default:
			rows = append(rows, p.text)
			joinable, dropped = true, dropped && p.text == ""
		}
	}
	// and the viewport's height, so blank rows at either end are padding too
	for len(rows) > 0 && rows[0] == "" {
		rows = rows[1:]
	}
	for len(rows) > 0 && rows[len(rows)-1] == "" {
		rows = rows[:len(rows)-1]
	}
	return strings.Join(rows, "\n")
}

// quoteColumns are the columns of line under quote bars.
func quoteColumns(line string) map[int]bool {
	bar := quoteBar()
	skip := map[int]bool{}
	for at := 0; ; at += len(bar) {
		i := strings.Index(line[at:], bar)
		if i < 0 {
			return skip
		}
		at += i
		col := ansi.StringWidth(line[:at])
		skip[col], skip[col+1] = true, true
	}
}

func HighlightSelection(lines []string, sel Selection) []string {
	if sel.IsEmpty() {
		return lines
	}
	start, end := sel.Normalized()
	out := slices.Clone(lines)
	for row := max(0, start.Row); row <= end.Row && row < len(out); row++ {
		from, to := selBounds(out[row], sel, start, end, row)
		before, text, after := selectedRange(out[row], from, to, nil)
		if text != "" {
			out[row] = before + DefaultStyles.Cursor.Render(text) + after
		}
	}
	return out
}
