package tui

import (
	"slices"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
)

// loginPick is a list a login step chooses from: its items, filtered and
// drawn by the shared listView like every other list screen.
type loginPick struct {
	items []PickerItem
	listView
}

// newLoginPick lists items under title, with the row keyed initial highlighted.
func newLoginPick(title string, items []PickerItem, initial string, width, height int) loginPick {
	p := loginPick{items: items, listView: newListView("Search")}
	p.setSize(width, height)
	rows := make([]listEntry, len(items))
	for i, item := range items {
		rows[i] = listEntry{
			key:     item.ID,
			section: title,
			name:    item.Label,
			desc:    item.Detail,
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
func (p loginPick) Highlighted() (PickerItem, bool) {
	row, ok := p.highlighted()
	if !ok {
		return PickerItem{}, false
	}
	i := slices.IndexFunc(p.items, func(item PickerItem) bool { return item.ID == row.key })
	if i < 0 {
		return PickerItem{}, false
	}
	return p.items[i], true
}

// Init starts the cursor blinking in the search line.
func (p loginPick) Init() tea.Cmd { return textinput.Blink }

// loginPane is an item's detail: what it is, what it holds, and what enter
// or a key would do with it.
func loginPane(item PickerItem, width int) []string {
	lines := paneTitle(item.Label, "", width)
	if item.Detail != "" {
		lines = append(lines, factRows("details", item.Detail, width)...)
	}
	if item.Note != "" {
		lines = append(lines, "")
		lines = append(lines, paneNote(item.Note, width)...)
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
