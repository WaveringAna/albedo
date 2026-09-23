package tui

import (
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"strings"

	"github.com/charmbracelet/bubbles/cursor"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
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
	ti := textinput.New()
	ti.Cursor.SetMode(cursor.CursorStatic)
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

func (m *PickerModel) SetSize(width, height int) {
	m.Width = width
	m.Height = height
	m.SearchInput.Width = max(1, width-8)
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

// selectableRows shares Ink's bottom-anchored list window and full-row inverse marker.
func inkWrap(text string, width int) string {
	if width <= 0 {
		return text
	}
	return ansi.Wrap(text, width, " ")
}

var inkRed = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
var inkYellow = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
var inkGreen = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
var inkCyan = lipgloss.NewStyle().Foreground(lipgloss.Color("6"))
var inkBrightCyan = lipgloss.NewStyle().Foreground(lipgloss.Color("14"))

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
		return styles.Dim.Render("no matches")
	}
	var b strings.Builder
	for i := first; i < min(len(lines), first+available); i++ {
		prefix := "  "
		if i == selected {
			prefix = "> "
		}
		line := prefix + lines[i]
		if width > 0 {
			line = ansi.Truncate(line, width, "…")
		}
		if i == selected {
			line = "\x1b[7m" + strings.ReplaceAll(line, "\x1b[0m", "\x1b[0m\x1b[7m") + "\x1b[0m"
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
		line += lipgloss.NewStyle().Faint(true).Render("  " + item.Detail)
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
	case tea.KeyMsg:
		switch msg.Type {
		case tea.KeyEsc, tea.KeyCtrlC, tea.KeyCtrlD:
			return m, func() tea.Msg { return PickerCancelMsg{} }
		case tea.KeyEnter:
			if len(m.Filtered) > 0 && m.Cursor < len(m.Filtered) {
				selectedID := m.Filtered[m.Cursor].ID
				return m, func() tea.Msg { return PickerSelectMsg{ID: selectedID} }
			}
			return m, nil
		case tea.KeyUp, tea.KeyCtrlP:
			if m.Cursor > 0 {
				m.Cursor--
			}
			return m, nil
		case tea.KeyDown, tea.KeyCtrlN:
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
		b.WriteString(m.Styles.Dim.Render("search: "))
		b.WriteString(m.SearchInput.View())
	} else {
		b.WriteString(m.Styles.Selected.Render(" "))
	}
	b.WriteByte('\n')
	b.WriteString(m.Styles.Dim.Render("↑↓ select · enter choose · esc cancel"))
	return b.String()
}
