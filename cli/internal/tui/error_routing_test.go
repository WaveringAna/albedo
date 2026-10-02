// TUI routing and in-flight save rendering cannot be exercised by daemon E2E
// tests. These checks keep display text from controlling either state machine.
package tui

import (
	"albedo/cli/internal/daemon"
	"errors"
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestCatalogFailureUsesErrorIdentity(t *testing.T) {
	for _, tc := range []struct {
		err  error
		show bool
	}{
		{fmt.Errorf("catalog: %w", &daemon.UpgradeRequiredError{Feature: "for commands"}), true},
		{errors.New("unrelated service needs an update"), false},
	} {
		m := AppModel{}
		next, _ := m.Update(commandCatalogLoadedMsg{Err: tc.err})
		if next.(AppModel).Notices.HasError() != tc.show {
			t.Fatalf("catalog failure was routed using its wording: %v", tc.err)
		}
	}
}

func TestExtensionSaveHidesConfirmationUntilFailure(t *testing.T) {
	m := NewExtensionPickerModel(nil, "session")
	m.Loading = false
	m.Width, m.Height = 80, 20
	m.Extensions = []ExtensionItem{{Name: "webhooks"}}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if !m.Saving || cmd == nil {
		t.Fatal("confirmation did not start the save")
	}
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "Reloading") || strings.Contains(view, "cancel") || strings.Contains(view, "confirm") {
		t.Fatalf("in-flight save still offers confirmation: %s", view)
	}
	m, _ = m.Update(extensionToggledMsg{Gen: m.Generation, Err: errors.New("save failed")})
	if m.Saving || !m.Confirming || !strings.Contains(ansi.Strip(m.View()), "retry") {
		t.Fatal("failed save did not restore the retry prompt")
	}
}
