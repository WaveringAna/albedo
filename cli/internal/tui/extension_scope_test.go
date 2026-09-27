// Extension scope toggling guards global defaults against accidental deletion and confirms inheritance.
// Confirmation and scope navigation states live in unexported picker model fields;
// E2E lacks a PTY harness to observe modal prompts before dispatch.
package tui

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestExtensionsOpenOnGlobalDefaultsAndScopeToSessionOnRequest(t *testing.T) {
	m := NewExtensionPickerModel(nil, "s")
	m.SetSize(120, 30)
	m, _ = m.Update(extensionsLoadedMsg{Extensions: []ExtensionItem{
		{Name: "view", Enabled: true, GlobalEnabled: false, Overridden: true},
		{Name: "bash", Enabled: true, GlobalEnabled: true},
	}})
	view := ansi.Strip(m.View())
	if m.Session || !strings.Contains(view, "global defaults") {
		t.Fatalf("the page should open on global defaults:\n%s", view)
	}
	if !strings.Contains(view, "off  view  this session: on") {
		t.Fatalf("global view should show the default and this session's own choice:\n%s", view)
	}

	// x only drops a session choice, and only in session scope.
	m, _ = m.Update(tea.KeyPressMsg{Code: 'x', Text: "x"})
	if m.Confirming {
		t.Fatal("x must not act on global defaults")
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 's', Text: "s"})
	view = ansi.Strip(m.View())
	if !m.Session || !strings.Contains(view, "on   view  this session") || !strings.Contains(view, "bash  follows global") {
		t.Fatalf("session scope should mark own choices and inherited ones:\n%s", view)
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'x', Text: "x"})
	if !m.Confirming || !m.Inheriting || !strings.Contains(ansi.Strip(m.View()), "follow the global default") {
		t.Fatalf("x should confirm dropping the session choice:\n%s", ansi.Strip(m.View()))
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
	m, _ = m.Update(tea.KeyPressMsg{Code: 'x', Text: "x"})
	if m.Confirming {
		t.Fatal("x needs a session choice to drop")
	}

	// An older daemon only supports per-session choices.
	old := NewExtensionPickerModel(nil, "s")
	old, _ = old.Update(extensionsLoadedMsg{Extensions: []ExtensionItem{{Name: "bash", Enabled: true}}, NoGlobal: true})
	old, _ = old.Update(tea.KeyPressMsg{Code: 'g', Text: "g"})
	if !old.Session {
		t.Fatal("without daemon support the page must stay on this session")
	}
}
