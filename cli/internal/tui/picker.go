package tui

import (
	"slices"
	"strings"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

type PickerItem struct {
	ID     string
	Label  string
	Detail string
	// Group ranks its items apart from the other groups under a search;
	// groups keep the order they were listed in.
	Group int
	// Note is what a detail pane says about the item, where a list has one.
	Note string
	// hits are the characters of Label the search matched.
	hits []int
}

type PickerSelectMsg struct {
	ID string
}

type PickerCancelMsg struct{}

type PickerModel struct {
	Title       string
	Items       []PickerItem
	Filtered    []PickerItem
	SearchInput textinput.Model
	Cursor      int
	Width       int
	Height      int
	WithSearch  bool
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
	}
	m.applyFilter()

	if initialSelection != "" {
		if i := slices.IndexFunc(m.Filtered, func(it PickerItem) bool { return it.ID == initialSelection }); i >= 0 {
			m.Cursor = i
		}
	}

	return m
}

// Highlighted returns the item under the cursor.
func (m PickerModel) Highlighted() (PickerItem, bool) {
	if m.Cursor >= 0 && m.Cursor < len(m.Filtered) {
		return m.Filtered[m.Cursor], true
	}
	return PickerItem{}, false
}

func (m *PickerModel) SetSize(width, height int) {
	m.Width = width
	m.Height = height
	m.SearchInput.SetWidth(max(1, width-8))
}

// applyFilter keeps the items the search matches, ranked within their group
// by the shared fuzzy matcher. Groups keep their order, and an empty search
// keeps the listed order.
func (m *PickerModel) applyFilter() {
	item, ok := m.Highlighted()
	old := ""
	if ok {
		old = item.ID
	}
	words := searchWords(m.SearchInput.Value())
	type scored struct {
		item PickerItem
		rank matchRank
	}
	var order []int
	groups := map[int][]scored{}
	for _, it := range m.Items {
		rank, hits, ok := matchFields(words, it.Label, it.ID, it.Detail)
		if !ok {
			continue
		}
		if _, seen := groups[it.Group]; !seen {
			order = append(order, it.Group)
		}
		it.hits = hits
		groups[it.Group] = append(groups[it.Group], scored{it, rank})
	}
	m.Filtered = nil
	for _, group := range order {
		matches := groups[group]
		if len(words) > 0 {
			slices.SortStableFunc(matches, func(a, b scored) int { return b.rank.compare(a.rank) })
		}
		for _, s := range matches {
			m.Filtered = append(m.Filtered, s.item)
		}
	}
	m.Cursor = max(0, slices.IndexFunc(m.Filtered, func(item PickerItem) bool { return item.ID == old }))
}

// selectableRows is a bottom-anchored list window with the selected row on
// the selection surface.
func selectableRows(lines []string, selected, height, limit, width int) string {
	if height <= 0 {
		height = 24
	}
	if limit <= 0 {
		limit = height
	}
	available := max(1, min(limit, height-8))
	first := min(max(0, selected-available+1), max(0, len(lines)-available))
	if len(lines) == 0 {
		return DefaultStyles.Faint.Render("no matches")
	}
	var b strings.Builder
	bar := selectBar() + " "
	for i := first; i < min(len(lines), first+available); i++ {
		lead := "  "
		if i == selected {
			lead = bar
		}
		line := lead + lines[i]
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

func pickerRow(item PickerItem) string {
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
			if item, ok := m.Highlighted(); ok {
				return m, func() tea.Msg { return PickerSelectMsg{ID: item.ID} }
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
		lines[i] = pickerRow(item)
	}
	b.WriteString(selectableRows(lines, m.Cursor, m.Height, m.Height, m.Width))
	b.WriteByte('\n')
	if m.WithSearch {
		b.WriteString(promptLead())
		b.WriteString(m.SearchInput.View())
	}
	b.WriteByte('\n')
	b.WriteString(keyHints(hint{"↑↓", "select"}, hint{"enter", "choose"}, hint{"esc", "cancel"}))
	return b.String()
}
