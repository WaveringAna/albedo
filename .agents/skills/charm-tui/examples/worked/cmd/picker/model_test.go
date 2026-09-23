package main

import (
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"strings"
	"testing"
)

func press(m *model, r rune) tea.Cmd {
	text := ""
	if r >= 32 && r < 127 {
		text = string(r)
	}
	_, cmd := m.Update(tea.KeyPressMsg{Code: r, Text: text})
	return cmd
}

func TestPrintableKeysBelongToSearch(t *testing.T) {
	m := newModel(testItems())
	press(m, '/')
	for _, r := range "qj/k? " {
		press(m, r)
	}
	if m.input.Value() != "qj/k? " || !m.input.Focused() || m.result.Accepted {
		t.Fatalf("input=%q", m.input.Value())
	}
}

func TestModalEscapeDoesNotQuitOrReopen(t *testing.T) {
	m := newModel(testItems())
	press(m, tea.KeyEnter)
	if m.confirm == nil {
		t.Fatal("no confirmation")
	}
	cmd := press(m, tea.KeyEscape)
	if m.confirm != nil || m.result.Accepted || cmd != nil {
		t.Fatal("modal key leaked to list")
	}
	press(m, tea.KeyEnter)
	press(m, tea.KeyEnter)
	if !m.result.Accepted || m.result.ID != "a" {
		t.Fatal("confirmation lost its target")
	}
}

func TestNoMatchEnterDoesNothing(t *testing.T) {
	m := newModel(testItems())
	m.list.filter("missing")
	if cmd := press(m, tea.KeyEnter); cmd != nil || m.confirm != nil {
		t.Fatal("empty selection accepted")
	}
}

func TestPickerResizeAndRepeatedView(t *testing.T) {
	m := newModel(servers)
	for _, size := range [][2]int{{0, 0}, {1, 1}, {19, 6}, {24, 8}, {80, 24}} {
		m.Update(tea.WindowSizeMsg{Width: size[0], Height: size[1]})
		beforeCursor := m.list.cursor
		beforeTop := m.top
		view := m.View().Content
		if view != m.View().Content || beforeCursor != m.list.cursor || beforeTop != m.top {
			t.Fatal("View changed state")
		}
		if lipgloss.Width(view) > size[0] {
			t.Fatalf("overflow at %v", size)
		}
		if view != "" && len(strings.Split(view, "\n")) > size[1] {
			t.Fatalf("height overflow at %v", size)
		}
	}
}
