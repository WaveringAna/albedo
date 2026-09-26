package tui

import (
	"github.com/charmbracelet/x/ansi"
	"strings"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
)

type PickerItem struct {
	ID     string
	Label  string
	Detail string
}

type PickerSelectMsg struct {
	ID string
}

type PickerCancelMsg struct{}

type PickerModel struct {
	Title       string
	Items       []PickerItem
	Filtered    []PickerItem
	Cursor      int
	SearchInput textinput.Model
	WithSearch  bool
	Width       int
	Height      int
	Styles      Styles
}

func NewPickerModel(title string, items []PickerItem, withSearch bool, initialSelection string) PickerModel {
	ti := newTextInput()
	ti.Placeholder = ""
	ti.Focus()
	ti.Prompt = ""

	m := PickerModel{
		Title:       title,
		Items:       items,
		WithSearch:  withSearch,
		SearchInput: ti,
		Styles:      DefaultStyles,
	}
	m.applyFilter()

	if initialSelection != "" {
		for i, item := range m.Filtered {
			if item.ID == initialSelection {
				m.Cursor = i
				break
			}
		}
	}

	return m
}

// Highlighted returns the item under the cursor.
func (m PickerModel) Highlighted() (PickerItem, bool) {
	if m.Cursor < 0 || m.Cursor >= len(m.Filtered) {
		return PickerItem{}, false
	}
	return m.Filtered[m.Cursor], true
}

func (m *PickerModel) SetSize(width, height int) {
	m.Width = width
	m.Height = height
	m.SearchInput.SetWidth(max(1, width-8))
}

func (m *PickerModel) applyFilter() {
	old := ""
	if m.Cursor >= 0 && m.Cursor < len(m.Filtered) {
		old = m.Filtered[m.Cursor].ID
	}
	tokens := strings.Fields(strings.ToLower(m.SearchInput.Value()))
	m.Filtered = nil
	for _, item := range m.Items {
		haystack := strings.ToLower(item.ID + " " + item.Label + " " + item.Detail)
		found := true
		for _, token := range tokens {
			if !strings.Contains(haystack, token) {
				found = false
				break
			}
		}
		if found {
			m.Filtered = append(m.Filtered, item)
		}
	}
	m.Cursor = 0
	for i, item := range m.Filtered {
		if item.ID == old {
			m.Cursor = i
			break
		}
	}
}

// selectableRows is a bottom-anchored list window with the selected row on
// the selection surface.
func inkWrap(text string, width int) string {
	if width <= 0 {
		return text
	}
	return ansi.Wrap(text, width, " ")
}

func selectableRows(lines []string, selected, height, limit, width int, styles Styles) string {
	if height <= 0 {
		height = 24
	}
	if limit <= 0 {
		limit = height
	}
	available := max(1, min(limit, height-8))
	first := min(max(0, selected-available+1), max(0, len(lines)-available))
	if len(lines) == 0 {
		return styles.Faint.Render("no matches")
	}
	var b strings.Builder
	for i := first; i < min(len(lines), first+available); i++ {
		prefix := "  "
		if i == selected {
			prefix = selectBar() + " "
		}
		line := prefix + lines[i]
		if width > 0 {
			line = ansi.Truncate(line, width, "…")
		}
		if i == selected {
			line = selectedLine(line, width)
		}
		if i > first {
			b.WriteByte('\n')
		}
		b.WriteString(line)
	}
	return b.String()
}

func pickerRow(item PickerItem, styles Styles) string {
	line := item.Label
	if item.Detail != "" {
		line += DefaultStyles.Faint.Render("  " + item.Detail)
	}
	return line
}

func (m PickerModel) Init() tea.Cmd {
	if m.WithSearch {
		return textinput.Blink
	}
	return nil
}

func (m PickerModel) Update(msg tea.Msg) (PickerModel, tea.Cmd) {
	var cmd tea.Cmd

	switch msg := msg.(type) {
	case tea.KeyPressMsg:
		switch msg.String() {
		case "esc", "ctrl+c", "ctrl+d":
			return m, func() tea.Msg { return PickerCancelMsg{} }
		case "enter":
			if len(m.Filtered) > 0 && m.Cursor < len(m.Filtered) {
				selectedID := m.Filtered[m.Cursor].ID
				return m, func() tea.Msg { return PickerSelectMsg{ID: selectedID} }
			}
			return m, nil
		case "up", "ctrl+p":
			if m.Cursor > 0 {
				m.Cursor--
			}
			return m, nil
		case "down", "ctrl+n":
			if m.Cursor < len(m.Filtered)-1 {
				m.Cursor++
			}
			return m, nil
		}
	}

	if m.WithSearch {
		var tiCmd tea.Cmd
		m.SearchInput, tiCmd = m.SearchInput.Update(msg)
		m.applyFilter()
		cmd = tea.Batch(cmd, tiCmd)
	}

	return m, cmd
}

func (m PickerModel) View() string {
	var b strings.Builder
	if m.Title != "" {
		b.WriteString(m.Title)
		b.WriteByte('\n')
	}
	lines := make([]string, len(m.Filtered))
	for i, item := range m.Filtered {
		lines[i] = pickerRow(item, m.Styles)
	}
	b.WriteString(selectableRows(lines, m.Cursor, m.Height, m.Height, m.Width, m.Styles))
	b.WriteByte('\n')
	if m.WithSearch {
		b.WriteString(promptLead())
		b.WriteString(m.SearchInput.View())
	}
	b.WriteByte('\n')
	b.WriteString(keyHints(hint{"↑↓", "select"}, hint{"enter", "choose"}, hint{"esc", "cancel"}))
	return b.String()
}
