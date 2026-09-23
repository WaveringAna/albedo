package main

import (
	tea "charm.land/bubbletea/v2"
	"context"
	"testing"
)

func TestModelRejectsResultDuringDebounce(t *testing.T) {
	m := newModel(context.Background(), demoSearch)
	defer m.state.stop()
	a := m.initial
	_, load := m.Update(debounceMsg{ticket: a})
	if load == nil {
		t.Fatal("did not schedule backend")
	}
	m.input.Focus()
	m.Update(tea.KeyPressMsg{Code: 'b', Text: "b"})
	m.Update(loadedMsg{generation: a.generation, rows: []string{"obsolete"}})
	if m.state.query != "b" || m.state.phase != waiting || len(m.state.rows) != 0 {
		t.Fatal("adapter accepted obsolete result")
	}
}

func TestLoadCmdUsesCapturedQueryNotLiveModel(t *testing.T) {
	m := newModel(context.Background(), func(_ context.Context, q string) ([]string, error) { return []string{q}, nil })
	defer m.state.stop()
	a := m.state.change("captured")
	cmd := loadCmd(a, m.search)
	m.state.change("later")
	got := cmd().(loadedMsg)
	if got.rows[0] != "captured" || got.generation != a.generation {
		t.Fatal("command observed live state")
	}
}
