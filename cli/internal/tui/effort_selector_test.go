// Narrow-terminal clipping and escape need focused keyboard events.
package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestEffortSelectorEscapeAndNarrowLayout(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s1", Effort: "max"}, nil)
	m.SetSize(28, 15)
	m.openEffortSelector([]string{"low", "medium", "high", "xhigh", "max"})
	if line := m.effortSelectorView(); !strings.Contains(ansi.Strip(line), "[max]") || ansi.StringWidth(line) > m.chatWidth() {
		t.Fatalf("selected level clipped or line too wide: %q", line)
	}
	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	if cmd != nil || len(m.effortOptions) != 0 {
		t.Fatal("escape did not dismiss selector")
	}
	if len(m.History.Entries()) != 0 {
		t.Fatal("selector should not write to history")
	}
}
