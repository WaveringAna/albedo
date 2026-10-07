package tui

import (
	"slices"
	"strings"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// listEntry is one entry of a list screen: how it draws, what the filter
// matches, and what its detail pane says.
type listEntry struct {
	key     string // names the row across reloads, so the cursor stays on it
	section string // rows of one section sit together under its rule
	lead    string // styled state before the name, padded to the widest
	name    string // what the filter underlines
	desc    string // faint after the name, and searched
	tag     string // styled, at the right edge
	search  []string
	detail  func(width int) []string // the pane's lines; nil leaves it blank
}

type listShown struct {
	row  int
	hits []int
}

// listView is the state every list screen shares: a filter that is always
// live, the rows it leaves, the cursor, and how they draw. Keys that move
// or type belong to it; keys that act on a row belong to the screen, which
// asks for them first. Actions are therefore never bare letters.
type listView struct {
	input  textinput.Model
	rows   []listEntry
	shown  []listShown
	Cursor int
	height int
	// Empty is said when there are no rows at all.
	Empty string
}

// newFilter is a focused search field.
func newFilter(placeholder string) textinput.Model {
	input := newField()
	input.Placeholder = placeholder
	st := input.Styles()
	st.Focused.Placeholder, st.Blurred.Placeholder = DefaultStyles.Faint, DefaultStyles.Faint
	input.SetStyles(st)
	input.Focus()
	return input
}

func newListView(placeholder string) listView {
	return listView{input: newFilter(placeholder)}
}

func (l *listView) setSize(width, height int) {
	l.input.SetWidth(max(1, width-6))
	l.height = height
}

// setRows replaces the rows and filters them again, keeping the cursor on
// its row when that is still shown.
func (l *listView) setRows(rows []listEntry) {
	keep := ""
	if r, ok := l.highlighted(); ok {
		keep = r.key
	}
	l.rows = rows
	l.refilter(keep)
}

// refilter ranks the rows against the filter. Rows rank within their
// section and sections by their best row; an empty filter keeps the order
// the rows came in.
func (l *listView) refilter(keep string) {
	words := searchWords(l.input.Value())
	type scored struct {
		shown listShown
		rank  matchRank
	}
	var order []string
	groups := map[string][]scored{}
	for i, r := range l.rows {
		rank, hits, ok := matchFields(words, append([]string{r.name, r.desc}, r.search...)...)
		if !ok {
			continue
		}
		if _, seen := groups[r.section]; !seen {
			order = append(order, r.section)
		}
		groups[r.section] = append(groups[r.section], scored{listShown{i, hits}, rank})
	}
	if len(words) > 0 {
		for _, g := range groups {
			slices.SortStableFunc(g, func(a, b scored) int { return b.rank.compare(a.rank) })
		}
		slices.SortStableFunc(order, func(a, b string) int { return groups[b][0].rank.compare(groups[a][0].rank) })
	}
	l.shown = l.shown[:0]
	for _, section := range order {
		for _, s := range groups[section] {
			l.shown = append(l.shown, s.shown)
		}
	}
	l.Cursor = max(0, slices.IndexFunc(l.shown, func(s listShown) bool { return l.rows[s.row].key == keep }))
}

func (l listView) highlighted() (listEntry, bool) {
	if l.Cursor < 0 || l.Cursor >= len(l.shown) {
		return listEntry{}, false
	}
	return l.rows[l.shown[l.Cursor].row], true
}

func (l *listView) move(by int) {
	l.Cursor = min(max(l.Cursor+by, 0), max(0, len(l.shown)-1))
}

// update takes the keys that move through the list and everything else
// into the filter.
func (l *listView) update(msg tea.Msg) tea.Cmd {
	if key, ok := msg.(tea.KeyPressMsg); ok {
		page := max(1, l.height/2)
		if by, moves := map[string]int{"up": -1, "ctrl+p": -1, "down": 1, "ctrl+n": 1, "pgup": -page, "pgdown": page}[key.String()]; moves {
			l.move(by)
			return nil
		}
	}
	before := l.input.Value()
	var cmd tea.Cmd
	l.input, cmd = l.input.Update(msg)
	if l.input.Value() != before {
		l.refilter("")
	}
	return cmd
}

func (l listView) filterLine() string { return promptLead() + l.input.View() }

// frame is the screen's layout around this list and the highlighted row's
// detail.
func (l listView) frame(title, right, footer string) listFrame {
	return listFrame{title: title, right: right, filter: l.filterLine(), list: l.list, pane: l.pane, footer: footer}
}

// list draws the rows under their section rules at exactly width × height.
func (l listView) list(width, height int) []string {
	if len(l.shown) == 0 {
		note := "  no matches"
		if len(l.rows) == 0 {
			note = "  " + l.Empty
		}
		return scrollWindow([]string{DefaultStyles.Faint.Render(note)}, -1, width, height)
	}
	leadW, nameW := 0, 0
	for _, s := range l.shown {
		r := l.rows[s.row]
		leadW = max(leadW, ansi.StringWidth(r.lead))
		nameW = max(nameW, ansi.StringWidth(r.name))
	}
	nameW = min(nameW, max(12, width/3))

	type line struct {
		text  string
		shown int // the row it draws, or -1 for a rule
	}
	var all []line
	selectedAt := -1
	for i, s := range l.shown {
		if section := l.rows[s.row].section; section != "" && (i == 0 || l.rows[l.shown[i-1].row].section != section) {
			run := 1
			for i+run < len(l.shown) && l.rows[l.shown[i+run].row].section == section {
				run++
			}
			if len(all) > 0 && height >= 10 {
				all = append(all, line{shown: -1})
			}
			all = append(all, line{text: sectionRule(section, run, width), shown: -1})
		}
		if i == l.Cursor {
			selectedAt = len(all)
		}
		all = append(all, line{shown: i})
	}
	return drawWindow(len(all), func(i int) string {
		if all[i].shown < 0 {
			return all[i].text
		}
		return l.row(l.shown[all[i].shown], all[i].shown == l.Cursor, width, leadW, nameW)
	}, selectedAt, width, height)
}

func (l listView) row(s listShown, selected bool, width, leadW, nameW int) string {
	r := l.rows[s.row]
	bar, nameStyle := " ", lipgloss.NewStyle()
	if selected {
		bar, nameStyle = selectBar(), DefaultStyles.Bold
	}
	line := bar + " "
	if leadW > 0 {
		line += r.lead + strings.Repeat(" ", leadW-ansi.StringWidth(r.lead)+2)
	}
	line += markedCell(r.name, s.hits, nameW, nameStyle)
	room := width - ansi.StringWidth(line) - 3
	if r.tag != "" {
		room -= ansi.StringWidth(r.tag) + 2
	}
	if r.desc != "" && room >= 4 {
		line += DefaultStyles.Faint.Render("  " + ansi.Truncate(r.desc, room, "…"))
	}
	if r.tag != "" {
		line += strings.Repeat(" ", max(2, width-ansi.StringWidth(line)-ansi.StringWidth(r.tag)-1)) + r.tag
	}
	if selected {
		return selectedLine(line, width)
	}
	return line
}

// pane is the highlighted row's detail at exactly width × height.
func (l listView) pane(width, height int) []string {
	inner := max(1, width-2)
	r, ok := l.highlighted()
	switch {
	case !ok:
		return paneBox([]string{"", DefaultStyles.Muted.Render("nothing matches"), DefaultStyles.Faint.Render("Try fewer search terms")}, inner, width, height)
	case r.detail == nil:
		return paneBox(nil, inner, width, height)
	}
	return paneBox(r.detail(inner), inner, width, height)
}

// paneTitle opens a detail pane: the name in bold, a description under it,
// and a rule.
func paneTitle(name, description string, width int) []string {
	var lines []string
	for _, l := range svWrap(name, width, 2) {
		lines = append(lines, DefaultStyles.Bold.Render(l))
	}
	for _, l := range svWrap(description, width, 3) {
		if l != "" {
			lines = append(lines, DefaultStyles.Muted.Render(l))
		}
	}
	return append(lines, DefaultStyles.Decor.Render(strings.Repeat("─", width)))
}

// factRows is one labelled fact of a detail pane; a long value wraps under
// itself.
func factRows(label, value string, width int) []string {
	const labelW = 10
	var lines []string
	for i, l := range svWrap(value, max(1, width-labelW), 4) {
		cell := strings.Repeat(" ", labelW)
		if i == 0 {
			cell = DefaultStyles.Muted.Render(svCell(label, labelW, false))
		}
		lines = append(lines, cell+l)
	}
	return lines
}

// paneNote is faint explanatory text at the foot of a detail pane.
func paneNote(text string, width int) []string {
	var lines []string
	for _, l := range svWrap(text, width, 6) {
		lines = append(lines, DefaultStyles.Faint.Render(l))
	}
	return lines
}
