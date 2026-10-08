package tui

import (
	"cmp"
	"fmt"
	"slices"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// setDoc takes a document and its rows, keeping the cursor on the row it was on.
func (m *PageViewModel) setDoc(doc *PageDocument) {
	m.Doc = doc
	var rows []listEntry
	if doc != nil {
		rows = make([]listEntry, len(doc.Rows))
		for i, row := range doc.Rows {
			rows[i] = pageEntry(row)
		}
	}
	m.setRows(rows)
}

// focusRow moves the cursor to row id when the list shows it.
func (m *PageViewModel) focusRow(id string) {
	if i := slices.IndexFunc(m.shown, func(s listShown) bool { return m.rows[s.row].key == id }); i >= 0 {
		m.Cursor = i
	}
}

// pageEntry is how a row reads in the list: its tone dot in front, its text,
// its quiet #id at the edge, grouped under its badge.
func pageEntry(row PageRow) listEntry {
	tag := ""
	if id := rowID(row); id != "" {
		tag = DefaultStyles.Faint.Render(id)
	}
	return listEntry{
		key:     row.ID,
		section: row.Badge,
		lead:    toneGlyph(row.Tone),
		name:    row.Text,
		tag:     tag,
		search:  []string{row.ID, row.Badge},
		detail:  func(width int) []string { return pageDetail(row, width) },
	}
}

// toneGlyph is the dot a row wears for its tone; plain rows get a quiet one.
func toneGlyph(tone PageTone) string {
	switch tone {
	case ToneWarning, ToneActive:
		return toneStyle(tone).Render("●")
	}
	return DefaultStyles.Faint.Render("·")
}

// pageDetail is a row's pane: its text over its badge and id, then its
// detail paragraphs wrapped to the pane.
func pageDetail(row PageRow, width int) []string {
	meta := row.Badge
	if id := rowID(row); id != "" {
		meta += " · " + id
	}
	lines := paneTitle(row.Text, meta, width)
	for paragraph := range strings.SplitSeq(row.Detail, "\n\n") {
		if paragraph = strings.TrimSpace(paragraph); paragraph != "" {
			lines = append(lines, "")
			lines = append(lines, strings.Split(ansi.Wrap(paragraph, width, " -"), "\n")...)
		}
	}
	return lines
}

// hasDetail reports whether any row has a detail, the only case the pane shows.
func (m PageViewModel) hasDetail() bool {
	return m.Doc != nil && slices.ContainsFunc(m.Doc.Rows, func(r PageRow) bool { return r.Detail != "" })
}

// emptyText is what the list says when it has no rows.
func (m PageViewModel) emptyText() string {
	switch {
	case m.Doc != nil:
		return m.Doc.Empty
	case m.Error != "":
		return strings.TrimPrefix(m.Command, "/") + " did not load"
	}
	return "loading " + strings.TrimPrefix(m.Command, "/") + "…"
}

// toneStyle is the color a badge wears for its tone.
func toneStyle(tone PageTone) lipgloss.Style {
	switch tone {
	case ToneActive:
		return DefaultStyles.Success
	case ToneWarning:
		return DefaultStyles.Warning
	case ToneMuted:
		return DefaultStyles.Faint
	}
	return DefaultStyles.Muted
}

// rowID is the quiet #id a row shows, unless its id is its text.
func rowID(row PageRow) string {
	if row.ID != row.Text {
		return "#" + row.ID
	}
	return ""
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

// View draws the rows beside the highlighted row's detail; a prompt or a
// question takes the footer, and the filter steps aside while one is open.
func (m PageViewModel) View() string {
	width := cmp.Or(m.Width, 80)
	lv := m.listView
	lv.Empty = m.emptyText()
	right := ""
	if m.Doc != nil {
		right = DefaultStyles.Faint.Render(m.Doc.Summary)
	}
	f := lv.frame(brand("albedo")+" "+DefaultStyles.Muted.Render(m.Command), right, m.footer(width))
	if m.Mode != modeBrowse {
		f.filter = ""
	}
	if !m.hasDetail() {
		f.pane = nil
	}
	return f.view(m.Width, m.Height)
}

// prompt is the line above the keys where an action asks for what it needs,
// blank while browsing or asking a question.
func (m PageViewModel) prompt() string {
	if m.Mode == modeActions {
		labels := make([]string, len(m.Doc.Actions))
		for i, action := range m.Doc.Actions {
			labels[i] = action.Label
			if i == m.ActionIndex {
				labels[i] = "[" + action.Label + "]"
			}
		}
		return " Actions: " + strings.Join(labels, " · ")
	}
	act := m.CurrentAction
	if act == nil {
		return ""
	}
	target := ""
	if row := m.currentRow(); act.Row && row != nil {
		if id := rowID(*row); id != "" {
			target = " " + id
		}
	}
	switch m.Mode {
	case modeChoice:
		var options []string
		for i, opt := range m.fieldChoices() {
			label := " " + opt + " "
			if i == m.ChoiceIndex {
				label = selectedLine(label, 0)
			}
			options = append(options, label)
		}
		return " " + DefaultStyles.Prompt.Render(act.Label+target) + " " + promptLead() + strings.Join(options, "")
	case modeText:
		field := cmp.Or(m.currentField().Label, act.Label)
		return " " + DefaultStyles.Prompt.Render(act.Label+target+" · "+field) + " " + promptLead() + m.TextInput.View()
	}
	return ""
}

// footer is the prompt or question above the keys and one status: a failure,
// a notice, or work in flight.
func (m PageViewModel) footer(width int) string {
	if m.Mode == modeConfirm {
		return m.confirm.footer(width, m.Error)
	}
	status, urgent := m.status()
	line := footerLine(width, m.hints(), status, urgent)
	if prompt := m.prompt(); prompt != "" {
		return prompt + "\n" + line
	}
	return line
}

// status is the footer's state beside the keys; an urgent one takes a row of
// its own when the keys do not leave room for it.
func (m PageViewModel) status() (string, bool) {
	switch {
	case m.Error != "":
		return DefaultStyles.Error.Render(m.Error), true
	case m.Busy:
		return DefaultStyles.Busy.Render("working…"), true
	case m.Notice != "":
		return DefaultStyles.Warning.Render(m.Notice), true
	}
	return "", false
}

// hints is the keys for the mode the page is in, most important first.
func (m PageViewModel) hints() []hint {
	switch {
	case m.Busy:
		return []hint{{"esc", "back"}}
	case m.Doc == nil:
		return []hint{{"ctrl+r", "retry"}, {"esc", "back"}}
	case m.Mode == modeText:
		return []hint{{"enter", "save"}, {"esc", "cancel"}}
	case m.Mode == modeChoice:
		return []hint{{"←→", "choose"}, {"enter", "apply"}, {"esc", "cancel"}}
	case m.Mode == modeActions:
		return []hint{{"↑↓", "action"}, {"enter", "choose"}, {"esc", "cancel"}}
	}
	return m.browseHints()
}

// browseHints lists the row's chords with their labels, then the menu,
// refresh, and esc last.
func (m PageViewModel) browseHints() []hint {
	var hints []hint
	if len(m.rows) > 1 {
		hints = append(hints, hint{"↑↓", "move"})
	}
	for _, act := range m.Doc.Actions {
		if act.Key != "" && (!act.Row || m.currentRow() != nil) {
			hints = append(hints, hint{act.Key, act.Label})
		}
	}
	if len(m.Doc.Actions) > 0 {
		hints = append(hints, hint{"ctrl+a", "actions"})
	}
	return append(hints, hint{"ctrl+r", "refresh"}, hint{"esc", "back"})
}

// fitHints is " " and the hints in room columns. A screen lists its hints
// most important first and esc last. What the screen already says goes
// first: moving, then the least important hints one at a time from the end,
// always keeping esc, and only when three labelled hints no longer fit,
// every label but the keys. Empty when not even the keys fit.
func fitHints(hints []hint, room int) string {
	keysOnly := make([]hint, len(hints))
	for i, h := range hints {
		keysOnly[i] = hint{key: h.key}
		if h.key == "" {
			keysOnly[i].does = h.does
		}
	}
	still := slices.DeleteFunc(slices.Clone(hints), func(h hint) bool { return h.key == "↑↓" })
	candidates := [][]hint{hints, still}
	leaving := slices.IndexFunc(still, func(h hint) bool { return h.key == "esc" })
	if leaving >= 0 {
		staying := slices.Delete(slices.Clone(still), leaving, leaving+1)
		for n := len(staying) - 1; n >= min(2, len(staying)); n-- {
			candidates = append(candidates, append(slices.Clone(staying[:n]), still[leaving]))
		}
	}
	candidates = append(candidates, keysOnly)
	for _, candidate := range candidates {
		if line := " " + keyHints(candidate...); len(candidate) > 0 && ansi.StringWidth(line) <= room {
			return line
		}
	}
	return ""
}
