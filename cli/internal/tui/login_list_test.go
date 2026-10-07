// Login's lists and removal question are keystroke behaviour the e2e suite
// reaches only through the daemon's flows: a letter typed into the always-live
// search must not remove a provider (the old bare "d" did), removal waits for
// enter, and a text step takes letters as input rather than as actions.
package tui

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"

	tea "charm.land/bubbletea/v2"
)

func TestLoginRemovalAsksThenTakesEnterOnly(t *testing.T) {
	m := loginModel(120, 30)
	m, _ = m.Update(tea.KeyPressMsg{Code: 'd', Mod: tea.ModCtrl})
	if m.Step != StepRemove || !m.confirm.asking() {
		t.Fatalf("ctrl+d did not ask about the highlighted provider (step %v):\n%s", m.Step, ansi.Strip(m.View()))
	}
	m, cmd := m.Update(tea.KeyPressMsg{Code: 'x', Text: "x"})
	if cmd != nil || m.Step != StepRemove {
		t.Fatal("a stray key changed the removal question")
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if m.Step != StepChoose || m.confirm.asking() {
		t.Fatalf("esc did not keep the provider (step %v)", m.Step)
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'd', Mod: tea.ModCtrl})
	m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.Step != StepSaving || cmd == nil {
		t.Fatalf("enter did not remove (step %v)", m.Step)
	}
}

func TestLoginLetterInTheSearchFiltersInsteadOfRemoving(t *testing.T) {
	m := loginModel(120, 30)
	m, _ = m.Update(tea.KeyPressMsg{Code: 'd', Text: "d"})
	if m.Step != StepChoose || m.confirm.asking() {
		t.Fatalf("a bare letter started a removal (step %v)", m.Step)
	}
	if m.ChoosePicker.input.Value() != "d" {
		t.Fatalf("the letter did not reach the search: %q", m.ChoosePicker.input.Value())
	}
}

func TestLoginFilterFuzzilyFindsAProvider(t *testing.T) {
	m := loginModel(120, 30)
	for _, r := range "cla" {
		m, _ = m.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "claude-team") || strings.Contains(view, "Antigravity") {
		t.Fatalf("the search did not narrow to the claude providers:\n%s", view)
	}
	if item, ok := m.ChoosePicker.Highlighted(); !ok || !strings.HasPrefix(item.ID, "use:claude") && !strings.HasPrefix(item.ID, "signin:claude") {
		t.Fatalf("the best match is not a claude row: %+v", item)
	}
}

func TestLoginDetailShowsWithoutEnter(t *testing.T) {
	m := loginModel(120, 30)
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "a saved provider profile") {
		t.Fatalf("the highlighted provider's detail is not in the pane:\n%s", view)
	}
}

func TestLoginKeyEntryTakesLettersAsInput(t *testing.T) {
	m := loginModel(120, 30)
	m.askAPIKey()
	for _, r := range "dx" {
		m, _ = m.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	if m.TextInput.Value() != "dx" || m.Step != StepAPIKey {
		t.Fatalf("typing into the key step went elsewhere: %q on step %v", m.TextInput.Value(), m.Step)
	}
}
