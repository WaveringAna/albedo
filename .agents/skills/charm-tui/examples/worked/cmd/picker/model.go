package main

import (
	"charm.land/bubbles/v2/help"
	"charm.land/bubbles/v2/key"
	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"example.com/charm-tui-worked/internal/display"
	"fmt"
	"strings"
)

type model struct {
	list               selection
	input              textinput.Model
	help               help.Model
	width, height, top int
	confirm            *item // Captured target, not a later lookup through a moving cursor.
	result             outcome
}

type keys struct{ up, down, search, accept, back, quit key.Binding }

func binding(k, label string) key.Binding {
	return key.NewBinding(key.WithKeys(k), key.WithHelp(k, label))
}
func (k keys) ShortHelp() []key.Binding {
	return []key.Binding{k.up, k.down, k.search, k.accept, k.back, k.quit}
}
func (k keys) FullHelp() [][]key.Binding { return [][]key.Binding{k.ShortHelp()} }

func (m *model) keys() keys {
	k := keys{binding("up", "up"), binding("down", "down"), binding("/", "search"), binding("enter", "choose"), binding("esc", "cancel"), binding("q", "quit")}
	if m.input.Focused() {
		k.up.SetEnabled(false)
		k.down.SetEnabled(false)
		k.search.SetEnabled(false)
		k.quit.SetEnabled(false)
		k.accept = binding("enter", "browse")
		k.back = binding("esc", "browse")
	} else if m.confirm != nil {
		k.up.SetEnabled(false)
		k.down.SetEnabled(false)
		k.search.SetEnabled(false)
		k.quit.SetEnabled(false)
		k.accept = binding("enter", "confirm")
		k.back = binding("esc", "back")
	} else {
		_, ok := m.list.current()
		k.accept.SetEnabled(ok)
	}
	return k
}

func newModel(items []item) *model {
	input := textinput.New()
	input.Prompt = "/ "
	input.Placeholder = "filter servers"
	input.SetVirtualCursor(true) // Avoid real-cursor coordinate translation here.
	input.SetWidth(48)
	return &model{list: newSelection(items), input: input, help: help.New(), width: 60, height: 12}
}

func (m *model) Init() tea.Cmd { return tea.RequestBackgroundColor }

func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = min(72, max(0, msg.Width))
		m.height = min(12, max(0, msg.Height))
		m.input.SetWidth(max(1, m.width-3))
		m.help.SetWidth(m.width)
		m.clampWindow()
		return m, nil
	case tea.BackgroundColorMsg:
		m.input.SetStyles(textinput.DefaultStyles(msg.IsDark()))
		m.help.Styles = help.DefaultStyles(msg.IsDark())
		return m, nil
	case tea.KeyPressMsg:
		if msg.String() == "ctrl+c" {
			m.result = outcome{Interrupted: true}
			return m, tea.Quit
		}
		// Modal input is consumed exactly once, even when this key closes it.
		if m.confirm != nil {
			switch msg.String() {
			case "esc":
				m.confirm = nil
			case "enter":
				m.result = outcome{Accepted: true, ID: m.confirm.ID}
				return m, tea.Quit
			}
			return m, nil
		}
		k := m.keys()
		// An editor owns printable keys. 'q', '/', '?', 'j' are text here.
		if m.input.Focused() {
			if key.Matches(msg, k.back, k.accept) {
				m.input.Blur()
				m.clampWindow()
				return m, nil
			}
			return m, m.updateInput(msg)
		}
		switch {
		case key.Matches(msg, k.quit, k.back):
			return m, tea.Quit
		case key.Matches(msg, k.search):
			cmd := m.input.Focus()
			m.clampWindow()
			return m, cmd
		case key.Matches(msg, k.up):
			m.list.move(-1)
		case key.Matches(msg, k.down):
			m.list.move(1)
		case key.Matches(msg, k.accept):
			if row, ok := m.list.current(); ok {
				m.confirm = &row
			}
		}
		m.clampWindow()
		return m, nil
	}
	// Paste results and cursor messages also need the child update path.
	return m, m.updateInput(msg)
}

func (m *model) updateInput(msg tea.Msg) tea.Cmd {
	before := m.input.Value()
	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	if m.input.Value() != before {
		m.list.filter(m.input.Value())
		m.clampWindow()
	}
	return cmd // Never lose child effects, including cursor or paste commands.
}

func (m *model) bodyHeight() int {
	// Header has exactly two clipped lines; status has one, help is measured.
	return display.BodyRows(m.height, 2, 1+lipgloss.Height(m.help.View(m.keys())))
}
func (m *model) clampWindow() {
	m.top, _ = display.Window(len(m.list.visible), m.list.cursor, m.top, m.bodyHeight())
}

func (m *model) View() tea.View {
	if m.width <= 0 || m.height <= 0 {
		return tea.NewView("")
	}
	if m.width < 20 || m.height < 7 {
		return tea.NewView(display.Line("resize · ctrl+c cancel", m.width))
	}
	title := lipgloss.NewStyle().Bold(true).Render("choose a server")
	if m.confirm != nil {
		// Modal panel replaces the content; it is not an overlay compositor.
		text := "use " + display.SingleLine(m.confirm.Label) + "?"
		content := title + "\n" + display.Panel(text, m.width) + "\n" + m.help.View(m.keys())
		return tea.NewView(content)
	}
	height := m.bodyHeight()
	lo, hi := display.Window(len(m.list.visible), m.list.cursor, m.top, height)
	lines := make([]string, 0, hi-lo)
	for i := lo; i < hi; i++ {
		row := m.list.items[m.list.visible[i]]
		lines = append(lines, display.Row(row.Label, row.Detail, m.width, i == m.list.cursor))
	}
	if len(m.list.visible) == 0 {
		lines = append(lines, "no matches · edit the filter")
	}
	content := []string{
		title, display.Line(m.input.View(), m.width),
		display.FillRows(lines, m.width, height),
		display.Line(fmt.Sprintf("%d matches", len(m.list.visible)), m.width),
		m.help.View(m.keys()),
	}
	return tea.NewView(strings.Join(content, "\n")) // Deliberately inline.
}
