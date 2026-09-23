package main

import (
	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"context"
	"example.com/charm-tui-worked/internal/display"
	"fmt"
	"strings"
	"time"
)

type debounceMsg struct {
	ticket ticket
	err    error
}
type loadedMsg struct {
	generation uint64
	rows       []string
	err        error
}

func debounceCmd(t ticket) tea.Cmd {
	return func() tea.Msg { return debounceMsg{ticket: t, err: await(t.ctx, 150*time.Millisecond)} }
}
func loadCmd(t ticket, search searchFunc) tea.Cmd {
	// The closure captures values and a service, never the live model.
	return func() tea.Msg {
		rows, err := search(t.ctx, t.query)
		return loadedMsg{generation: t.generation, rows: rows, err: err}
	}
}

type model struct {
	input         textinput.Model
	state         searchState
	search        searchFunc
	initial       ticket
	width, height int
}

func newModel(ctx context.Context, search searchFunc) *model {
	input := textinput.New()
	input.Prompt = "/ "
	input.Placeholder = "try slow, error, or queue"
	input.SetVirtualCursor(true)
	input.SetWidth(55)
	m := &model{input: input, state: searchState{root: ctx}, search: search, width: 60, height: 12}
	m.initial = m.state.change("")
	return m
}

func (m *model) Init() tea.Cmd {
	return tea.Batch(m.input.Focus(), debounceCmd(m.initial), tea.RequestBackgroundColor)
}

func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = min(72, max(0, msg.Width))
		m.height = min(12, max(0, msg.Height))
		m.input.SetWidth(max(1, m.width-3))
		return m, nil
	case tea.BackgroundColorMsg:
		m.input.SetStyles(textinput.DefaultStyles(msg.IsDark()))
		return m, nil
	case tea.KeyPressMsg:
		switch msg.String() {
		case "esc", "ctrl+c":
			m.state.stop()
			return m, tea.Quit
		case "ctrl+r":
			return m, debounceCmd(m.state.change(m.input.Value()))
		}
	case debounceMsg:
		// begin also rejects a duplicated current-generation debounce delivery.
		if !m.state.begin(msg.ticket.generation) {
			return m, nil
		}
		if msg.err != nil {
			m.state.complete(msg.ticket.generation, nil, msg.err)
			return m, nil
		}
		return m, loadCmd(msg.ticket, m.search)
	case loadedMsg:
		m.state.complete(msg.generation, msg.rows, msg.err)
		return m, nil
	}
	before := m.input.Value()
	var childCmd tea.Cmd
	m.input, childCmd = m.input.Update(msg)
	if m.input.Value() != before {
		t := m.state.change(m.input.Value())
		return m, tea.Batch(childCmd, debounceCmd(t))
	}
	return m, childCmd
}

func (m *model) View() tea.View {
	if m.width <= 0 || m.height <= 0 {
		return tea.NewView("")
	}
	if m.width < 20 || m.height < 6 {
		return tea.NewView(display.Line("resize · esc quit", m.width))
	}
	status := "waiting for input"
	switch m.state.phase {
	case waiting:
		status = "waiting for typing to settle"
	case loading:
		status = "searching…"
	case ready:
		status = fmt.Sprintf("%d matches", len(m.state.rows))
	case failed:
		status = "search failed · ctrl+r retry"
	}
	rows := make([]string, 0, len(m.state.rows))
	for _, row := range m.state.rows {
		rows = append(rows, display.SingleLine(row))
	}
	if m.state.phase == ready && len(rows) == 0 {
		rows = append(rows, "no matches · edit the query")
	}
	if m.state.err != nil {
		rows = append(rows, display.SingleLine(m.state.err.Error()))
	}
	// All four chrome rows are explicitly clipped to one line.
	content := []string{
		display.Line("server search · simulated service", m.width),
		display.Line(m.input.View(), m.width),
		display.Line(status, m.width),
		display.FillRows(rows, m.width, display.BodyRows(m.height, 3, 1)),
		display.Line("esc quit · ctrl+r retry", m.width),
	}
	return tea.NewView(strings.Join(content, "\n"))
}
