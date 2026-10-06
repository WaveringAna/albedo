package tui

import (
	"cmp"
	"fmt"
	"slices"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// pageLayout places the list and the selected row's detail under the title
// the way the sessions view does: side by side when there is room, the
// detail under the list when there is not, and the list alone when no row
// has one or the stack would leave the detail too little.
type pageLayout struct {
	list, pane int // widths side by side; pane is 0 when stacked or alone
	listRows   int // rows the list keeps
	paneRows   int // rows the detail keeps under the list; 0 unless stacked
}

func (m PageViewModel) layout(body, listed int) pageLayout {
	l := pageLayout{list: m.Width, listRows: body}
	if !slices.ContainsFunc(m.Doc.Rows, func(r PageRow) bool { return r.Detail != "" }) {
		return l
	}
	if m.Width >= 96 && m.Height >= 14 {
		l.list = m.Width / 2
		l.pane = m.Width - l.list - ansi.StringWidth(svSep())
		return l
	}
	// Stacked, the list keeps what it needs up to two fifths of the body, or
	// more when the detail is short, and the rule between them takes a row.
	rows := min(listed, max(3, body*2/5, body-1-len(m.detailLines(m.Width))))
	if body-rows-1 >= 4 {
		l.listRows, l.paneRows = rows, body-rows-1
	}
	return l
}

// list is the rows grouped under a rule per run of one badge, at exactly
// width × height, scrolled to keep the selection in view.
func (m PageViewModel) list(width, height int) []string {
	return scrollWindow(m.listLines(width, height), m.selectedAt(height), width, height)
}

func (m PageViewModel) listLines(width, height int) []string {
	if len(m.Doc.Rows) == 0 {
		return []string{m.Styles.Faint.Render("   " + m.Doc.Empty)}
	}
	idW := 0
	for _, row := range m.Doc.Rows {
		idW = max(idW, ansi.StringWidth(rowID(row)))
	}
	selected := m.currentIndex()
	var lines []string
	for i, row := range m.Doc.Rows {
		if i == 0 || row.Badge != m.Doc.Rows[i-1].Badge {
			if i > 0 && height >= 10 {
				lines = append(lines, "")
			}
			run := 1
			for run < len(m.Doc.Rows)-i && m.Doc.Rows[i+run].Badge == row.Badge {
				run++
			}
			lines = append(lines, sectionRule(row.Badge, run, width))
		}
		lines = append(lines, m.row(row, i == selected, width, idW))
	}
	return lines
}

// selectedAt is where the selected row sits in listLines.
func (m PageViewModel) selectedAt(height int) int {
	if len(m.Doc.Rows) == 0 {
		return 0
	}
	return m.lineOf(m.currentIndex(), height)
}

// listed is how many lines listLines makes, without drawing them.
func (m PageViewModel) listed(height int) int {
	return max(1, m.lineOf(len(m.Doc.Rows)-1, height)+1)
}

// lineOf is where row n sits in listLines.
func (m PageViewModel) lineOf(n, height int) int {
	at := 0
	for i, row := range m.Doc.Rows[:n+1] {
		if i == 0 || row.Badge != m.Doc.Rows[i-1].Badge {
			at++
			if i > 0 && height >= 10 {
				at++
			}
		}
		at++
	}
	return at - 1
}

// rowID is the quiet #id a row shows, unless its id is its text.
func rowID(row PageRow) string {
	if row.ID != row.Text {
		return "#" + row.ID
	}
	return ""
}

// row is one page row in the sessions view's grammar: bar, a glyph in the
// row's tone, the title, then its id right-aligned in idW columns.
func (m PageViewModel) row(row PageRow, selected bool, width, idW int) string {
	glyph, glyphStyle := "· ", m.Styles.Faint
	switch {
	case selected:
		glyph, glyphStyle = "◆ ", DefaultStyles.Agent
	case row.Tone == ToneWarning:
		glyph, glyphStyle = "● ", DefaultStyles.Warning
	case row.Tone == ToneActive:
		glyph, glyphStyle = "● ", DefaultStyles.Success
	}
	textStyle := lipgloss.NewStyle()
	switch {
	case selected:
		textStyle = DefaultStyles.Bold
	case row.Tone == ToneMuted:
		textStyle = m.Styles.Faint
	}
	textW := width - 4
	if idW > 0 {
		textW -= idW + 2
	}
	textW = max(1, textW)
	marker := " "
	if selected {
		marker = selectBar()
	}
	line := marker + glyphStyle.Render(glyph) + " " + textStyle.Render(svCell(row.Text, textW, false))
	if idW > 0 {
		line += "  " + m.Styles.Faint.Render(svCell(rowID(row), idW, true))
	}
	if selected {
		return selectedLine(line, width)
	}
	return line
}

// detail is the selected row at exactly width × height: its title and badge
// over a rule, then its detail wrapped to the pane, cut short with ··· when
// it runs past the bottom.
func (m PageViewModel) detail(width, height int) []string {
	lines := m.detailLines(width)
	if len(lines) > height && height > 0 {
		lines = append(lines[:height-1], m.Styles.Faint.Render("···"))
	}
	return paneBox(lines, max(1, width-2), width, height)
}

func (m PageViewModel) detailLines(width int) []string {
	inner := max(1, width-2)
	row := m.currentRow()
	if row == nil {
		return nil
	}
	var lines []string
	for _, l := range svWrap(row.Text, inner, 2) {
		lines = append(lines, DefaultStyles.Bold.Render(l))
	}
	meta := []string{toneStyle(row.Tone, m.Styles).Render(row.Badge)}
	if id := rowID(*row); id != "" {
		meta = append(meta, m.Styles.Faint.Render(id))
	}
	lines = append(lines, strings.Join(meta, DefaultStyles.Decor.Render(" · ")), DefaultStyles.Decor.Render(strings.Repeat("─", inner)))
	for paragraph := range strings.SplitSeq(row.Detail, "\n\n") {
		if paragraph = strings.TrimSpace(paragraph); paragraph != "" {
			lines = append(append(lines, ""), strings.Split(ansi.Wrap(paragraph, inner, " -"), "\n")...)
		}
	}
	return lines
}

// toneStyle is the color a badge wears for its tone.
func toneStyle(tone PageTone, styles Styles) lipgloss.Style {
	switch tone {
	case ToneActive:
		return DefaultStyles.Success
	case ToneWarning:
		return DefaultStyles.Warning
	case ToneMuted:
		return styles.Faint
	}
	return DefaultStyles.Muted
}

// pageNotice picks the wording for a finished action: the daemon's message
// when it sent one, else the action's label.
func pageNotice(msg pageActionExecutedMsg) string {
	notice := fmt.Sprintf("%s completed", msg.Action.Label)
	if msg.Message != "" {
		return msg.Message
	}
	return notice
}

func (m PageViewModel) View() string {
	width, height := cmp.Or(m.Width, 80), cmp.Or(m.Height, 24)
	summary := ""
	if m.Doc != nil {
		summary = m.Styles.Faint.Render(m.Doc.Summary)
	}
	lines := []string{" " + titleRule(width-1, brand("albedo")+" "+m.Styles.Muted.Render(m.Command), summary), ""}
	tail := []string{m.prompt(), m.footer(width)}
	body := max(1, height-len(lines)-len(tail))
	switch m.Doc {
	case nil:
		note := "loading " + m.Command + "…"
		if m.Error != "" {
			note = "r retry · esc back"
		}
		lines = append(lines, " "+m.Styles.Faint.Render(note))
		lines = append(lines, make([]string, max(0, body-1))...)
	default:
		l := m.layout(body, m.listed(body))
		list := m.list(l.list, l.listRows)
		if l.pane > 0 {
			pane := m.detail(l.pane, l.listRows)
			for i := range list {
				list[i] += svSep() + pane[i]
			}
		}
		lines = append(lines, list...)
		if l.paneRows > 0 {
			lines = append(lines, DefaultStyles.Decor.Render(strings.Repeat("─", width)))
			lines = append(lines, m.detail(width, l.paneRows)...)
		}
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

// prompt is the line above the footer where an action asks what it needs,
// blank while browsing.
func (m PageViewModel) prompt() string {
	if m.Mode == modeActions {
		var labels []string
		for i, action := range m.Doc.Actions {
			label := action.Label
			if i == m.ActionIndex {
				label = "[" + label + "]"
			}
			labels = append(labels, label)
		}
		return " Actions: " + strings.Join(labels, " · ")
	}
	act, row := m.CurrentAction, m.currentRow()
	if act == nil {
		return ""
	}
	target := ""
	if act.Row && row != nil {
		target = " "
		if id := rowID(*row); id != "" {
			target += id + " "
		}
		target += row.Text
	}
	switch m.Mode {
	case modeConfirm:
		return " " + DefaultStyles.Warning.Render(cmp.Or(act.Confirmation, act.Label+target+"?"))
	case modeChoice:
		var choice strings.Builder
		choice.WriteByte(' ')
		choice.WriteString(m.Styles.Prompt.Render(act.Label + target))
		choice.WriteByte(' ')
		choice.WriteString(promptLead())
		for i, opt := range m.fieldChoices() {
			label := " " + opt + " "
			if i == m.ChoiceIndex {
				label = selectedLine(label, 0)
			}
			choice.WriteString(label)
		}
		return choice.String()
	case modeText:
		return " " + m.Styles.Prompt.Render(act.Label+target+" · "+cmp.Or(m.currentField().Label, act.Label)) + " " + promptLead() + m.TextInput.View()
	}
	return ""
}

// fitHints is " " and the hints in room columns, shedding what the screen
// already says first: moving, then leaving, then every label but the keys.
// Empty when not even the keys fit.
func fitHints(hints []hint, room int) string {
	keysOnly := make([]hint, len(hints))
	for i, h := range hints {
		keysOnly[i] = hint{key: h.key}
		if h.key == "" {
			keysOnly[i].does = h.does
		}
	}
	still := slices.DeleteFunc(slices.Clone(hints), func(h hint) bool { return h.key == "↑↓" })
	staying := slices.DeleteFunc(slices.Clone(still), func(h hint) bool { return h.key == "esc" })
	for _, candidate := range [][]hint{hints, still, staying, keysOnly} {
		if line := " " + keyHints(candidate...); len(candidate) > 0 && ansi.StringWidth(line) <= room {
			return line
		}
	}
	return ""
}

// footer is the keys on the left and the last outcome on the right, the
// way the folder picker words it; a long outcome takes the whole line.
func (m PageViewModel) footer(width int) string {
	var hints []hint
	switch {
	case m.Busy:
		hints = []hint{{"working…", ""}}
	case m.Doc == nil:
		hints = []hint{{"esc", "back"}}
	case m.Mode == modeActions:
		return " " + keyHints(hint{"↑↓", "action"}, hint{"enter", "choose"}, hint{"esc", "cancel"})
	case m.Mode == modeBrowse:
		if len(m.Doc.Actions) > 0 {
			hints = append(hints, hint{"ctrl+a", "actions"})
		}
		if len(m.Doc.Rows) > 1 {
			hints = append(hints, hint{"↑↓", "move"})
		}
		for _, act := range m.Doc.Actions {
			if act.Key != "" && (!act.Row || m.currentRow() != nil) {
				hints = append(hints, hint{act.Key, act.Label})
			}
		}
		hints = append(hints, hint{"esc", "back"})
	case m.Mode == modeText:
		hints = []hint{{"enter", "save"}, {"esc", "cancel"}}
	case m.Mode == modeChoice:
		hints = []hint{{"←→", "choose"}, {"enter", "apply"}, {"esc", "cancel"}}
	default:
		hints = []hint{{"enter", "confirm"}, {"esc", "cancel"}}
	}
	var right string
	switch {
	case m.Error != "":
		right = DefaultStyles.Error.Render(m.Error)
	case m.Notice != "":
		right = m.Styles.Faint.Render(m.Notice)
	}
	room := width - 1
	if right != "" {
		room = width - ansi.StringWidth(right) - 3
	}
	left := fitHints(hints, room)
	if left == "" && right == "" {
		left = " " + ansi.Truncate(keyHints(hints...), width-2, "…")
	}
	return left + strings.Repeat(" ", max(1, width-ansi.StringWidth(left)-ansi.StringWidth(right)-1)) + right
}
