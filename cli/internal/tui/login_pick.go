package tui

import (
	"cmp"
	"slices"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
)

// loginItem is one row of a login list: what the screen acts on, how the row
// reads at a glance, and what its detail pane says.
type loginItem struct {
	ID      string
	Label   string
	Detail  string // faint after the name, and the pane's subtitle
	section string // the rule the row sits under; empty takes the list's label
	lead    string // styled state before the name, padded to the widest
	tag     string // styled metadata at the right edge
	facts   []loginFact
	note    string // the pane's closing line
}

// loginFact is one labelled fact in an item's pane.
type loginFact struct{ label, value string }

// loginPick is a list a login step chooses from: its items, filtered and
// drawn by the shared listView like every other list screen.
type loginPick struct {
	items []loginItem
	listView
}

// newLoginPick lists items under title, with the row keyed initial
// highlighted. An item's own section wins over the title, so one list can
// group several kinds of row.
func newLoginPick(title string, items []loginItem, initial string, width, height int) loginPick {
	p := loginPick{items: items, listView: newListView("Search")}
	p.setSize(width, height)
	rows := make([]listEntry, len(items))
	for i, item := range items {
		rows[i] = listEntry{
			key:     item.ID,
			section: cmp.Or(item.section, title),
			lead:    item.lead,
			name:    item.Label,
			desc:    item.Detail,
			tag:     item.tag,
			detail:  func(w int) []string { return loginPane(item, w) },
		}
	}
	p.setRows(rows)
	if i := slices.IndexFunc(p.shown, func(s listShown) bool { return p.rows[s.row].key == initial }); i >= 0 {
		p.Cursor = i
	}
	return p
}

// Highlighted is the item under the cursor.
func (p loginPick) Highlighted() (loginItem, bool) {
	row, ok := p.highlighted()
	if !ok {
		return loginItem{}, false
	}
	i := slices.IndexFunc(p.items, func(item loginItem) bool { return item.ID == row.key })
	if i < 0 {
		return loginItem{}, false
	}
	return p.items[i], true
}

// Init starts the cursor blinking in the search line.
func (p loginPick) Init() tea.Cmd { return textinput.Blink }

// loginPane is an item's detail: what it is, its facts, and what enter does
// with it.
func loginPane(item loginItem, width int) []string {
	lines := paneTitle(item.Label, item.Detail, width)
	for _, fact := range item.facts {
		lines = append(lines, factRows(fact.label, fact.value, width)...)
	}
	if item.note != "" {
		lines = append(lines, "")
		lines = append(lines, paneNote(item.note, width)...)
	}
	return lines
}

// pickerFor returns the list the current step shows.
func (m *LoginModel) pickerFor() *loginPick {
	switch m.Step {
	case StepProtocol:
		return &m.ProtocolPicker
	case StepModels, StepOAuthModels:
		return &m.ModelPicker
	}
	return &m.ChoosePicker
}

// listing reports whether the step shows a list rather than a question. A
// catalog still loading is a question until its models arrive.
func (m LoginModel) listing() bool {
	switch m.Step {
	case StepChoose, StepAccountProfile, StepOAuthFlow, StepProtocol:
		return true
	case StepModels, StepOAuthModels:
		return m.Catalog != nil
	case StepOAuthFields:
		return m.choiceField()
	}
	return false
}

// choiceField reports the sign-in field being asked is a list of choices.
func (m LoginModel) choiceField() bool {
	if m.Step != StepOAuthFields || m.LoginFieldIndex >= len(m.LoginFields) {
		return false
	}
	field := m.LoginFields[m.LoginFieldIndex]
	return field.Type == "choice" || field.Type == "boolean"
}

// pickUpdate routes a message to the list the step shows. Enter and esc
// answer with the messages the step already handles; every other key moves
// or types in the search.
func (m *LoginModel) pickUpdate(msg tea.Msg) tea.Cmd {
	p := m.pickerFor()
	key, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return p.update(msg)
	}
	switch key.String() {
	case "enter":
		item, found := p.Highlighted()
		if !found || !m.listing() {
			return nil
		}
		return func() tea.Msg { return PickerSelectMsg{ID: item.ID} }
	case "esc", "ctrl+c":
		return func() tea.Msg { return PickerCancelMsg{} }
	}
	return p.update(msg)
}
