// Checkpoint picking filters by typing, shows each checkpoint's detail beside
// the list, and asks before branching with enter and esc only. E2E cannot see
// the question or the stray-key handling, so these assert the model directly.
package tui

import (
	"albedo/cli/internal/daemon"
	"errors"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func treeFixture(t *testing.T) TreePickerModel {
	t.Helper()
	m := NewTreePickerModel(nil, "s")
	m.SetSize(120, 30)
	m, _ = m.Update(treeLoadedMsg{Gen: m.Generation, Items: []daemon.TreeCheckpoint{
		{ID: "a", Type: "user", Preview: "fix the parser"},
		{ID: "b", Type: "assistant", Preview: "wrote the adapter tests"},
	}})
	if m.Loading || len(m.Checkpoints) != 2 {
		t.Fatal("fixture checkpoints did not load")
	}
	return m
}

func TestTreeFilterAndDetailWithoutEnter(t *testing.T) {
	m := treeFixture(t)
	for _, r := range "adapter" {
		m, _ = m.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "wrote the adapter tests") || strings.Contains(view, "fix the parser") {
		t.Fatalf("typing should filter the checkpoints:\n%s", view)
	}
	if !strings.Contains(view, "fresh Python namespace.") {
		t.Fatalf("the branch detail should show beside the list without enter:\n%s", view)
	}
	if row, _ := m.highlighted(); row.key != "b" {
		t.Fatalf("the filter left %q under the cursor", row.key)
	}
}

func TestTreeAsksBeforeBranchingWithEnterAndEsc(t *testing.T) {
	m := treeFixture(t)
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if !m.Confirming() || !strings.Contains(ansi.Strip(m.View()), "Branch after user · fix the parser?") {
		t.Fatalf("enter should ask before branching:\n%s", ansi.Strip(m.View()))
	}
	m, cmd := m.Update(tea.KeyPressMsg{Code: 'y', Text: "y"})
	if cmd != nil || !m.Confirming() || m.Forking {
		t.Fatal("a stray key answered the branch question")
	}
	m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if cmd != nil || m.Confirming() {
		t.Fatal("esc should cancel the question, not leave the picker")
	}

	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if !m.Forking || cmd == nil {
		t.Fatal("the second enter should start the branch")
	}
}

func TestTreeForkFailureKeepsTheQuestionForRetry(t *testing.T) {
	m := treeFixture(t)
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	m, _ = m.Update(treeForkedMsg{Gen: m.Generation, Err: errors.New("branch refused")})
	view := ansi.Strip(m.View())
	if m.Forking || !m.Confirming() || !strings.Contains(view, "branch refused") || !strings.Contains(view, "retry") {
		t.Fatalf("a failed branch should keep the question open with retry:\n%s", view)
	}
}
