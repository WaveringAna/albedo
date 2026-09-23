package main

import (
	tea "charm.land/bubbletea/v2"
	"context"
	"example.com/charm-tui-worked/internal/display"
	"fmt"
	"strings"
)

type lineMsg string
type closedMsg struct{}

func waitForLine(ctx context.Context, ch <-chan string) tea.Cmd {
	return func() tea.Msg {
		line, ok := receive(ctx, ch)
		if !ok {
			return closedMsg{}
		}
		return lineMsg(line)
	}
}

type model struct {
	ctx           context.Context
	cancel        context.CancelFunc
	events        <-chan string
	history       history
	width, height int
	ended         bool
}

func (m *model) rows() int     { return display.BodyRows(m.height, 1, 2) }
func (m *model) Init() tea.Cmd { return waitForLine(m.ctx, m.events) }
func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = max(0, msg.Width)
		m.height = max(0, msg.Height)
		m.history.resize(m.rows())
	case tea.KeyPressMsg:
		switch msg.String() {
		case "q", "ctrl+c":
			m.cancel()
			return m, tea.Quit
		case "up", "k":
			m.history.scroll(-1, m.rows())
		case "down", "j":
			m.history.scroll(1, m.rows())
		case "end":
			m.history.latest(m.rows())
		}
	case lineMsg:
		if m.ended {
			return m, nil
		}
		m.history.append(string(msg), m.rows())
		return m, waitForLine(m.ctx, m.events) // Exactly one successor listener.
	case closedMsg:
		m.ended = true
		return m, nil // Never re-arm a closed stream.
	}
	return m, nil
}
func (m *model) View() tea.View {
	v := tea.NewView("")
	v.AltScreen = true
	if m.width <= 0 || m.height <= 0 {
		return v
	}
	if m.width < 20 || m.height < 5 {
		v.Content = display.Line("resize · q quit", m.width)
		return v
	}
	state := "following"
	if !m.history.follow {
		state = fmt.Sprintf("reading · %d new · end follows", m.history.unseen)
	}
	if m.history.expired {
		state = "old anchor evicted · end follows"
	}
	if m.ended {
		state += " · stream ended"
	}
	state += fmt.Sprintf(" · %d evicted", m.history.first)
	lines := m.history.visible(m.rows())
	for i := range lines {
		lines[i] = display.SingleLine(lines[i])
	}
	v.Content = strings.Join([]string{
		display.Line("worker events · retain last 32 records", m.width),
		display.FillRows(lines, m.width, m.rows()),
		display.Line(state, m.width),
		display.Line("↑/↓ scroll · end latest · q quit", m.width),
	}, "\n")
	return v
}
