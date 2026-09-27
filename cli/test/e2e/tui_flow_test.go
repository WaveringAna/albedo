// Effort selection crosses the composer, model registry, keyboard, and daemon
// session. Stubbed command replies cannot catch a dropped request or commit.
package e2e

import (
	"strings"
	"testing"

	"albedo/cli/internal/tui"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestTUIEffortSelectorCommitsThroughTheDaemon(t *testing.T) {
	providerRoute(t, echoReply)
	d := newTUIDriver(t)

	// Selecting a model goes through the real composer: enter dispatches the
	// command, the app asks the daemon, and the answer lands in the model.
	d.App.Chat.TextArea.SetValue("/model o3-mini")
	dispatched, ok := d.Key(tea.KeyEnter).(tui.ChatExecuteCommandMsg)
	if !ok || dispatched.Name != "/model" || dispatched.Args != "o3-mini" {
		t.Fatalf("enter did not dispatch /model: %#v", dispatched)
	}
	d.Dispatch(dispatched)
	if d.App.ActiveSession == nil || d.App.ActiveSession.Model != "o3-mini" || d.App.ActiveSession.Effort != "medium" {
		t.Fatalf("the daemon's model switch did not land: %+v", d.App.ActiveSession)
	}

	// /effort arrives as the message the command menu submits for it; the
	// daemon, not a stub, decides which tiers the model offers and which one
	// is current.
	d.Dispatch(tui.ChatExecuteCommandMsg{Name: "/effort"})
	opened := d.View()
	for _, tier := range []string{"low", "medium", "high"} {
		if !strings.Contains(opened, tier) {
			t.Fatalf("the selector is missing tier %q:\n%s", tier, opened)
		}
	}
	if !strings.Contains(opened, "Reasoning effort") || !strings.Contains(opened, "[medium]") {
		t.Fatalf("the daemon's current tier is not selected:\n%s", opened)
	}
	if strings.Contains(opened, "› ") {
		t.Fatal("the composer must be hidden while choosing effort")
	}

	// Even a narrow selector stays inside the terminal and Escape restores the
	// composer without changing the daemon.
	d.Update(tea.WindowSizeMsg{Width: 28, Height: 14})
	for _, line := range strings.Split(d.View(), "\n") {
		if width := ansi.StringWidth(line); width > 28 {
			t.Fatalf("effort selector rendered a %d-cell line at width 28: %q", width, line)
		}
	}
	d.Key(tea.KeyEscape)
	if view := d.View(); strings.Contains(view, "Reasoning effort") || !strings.Contains(view, "› ") {
		t.Fatalf("Escape did not restore the composer:\n%s", view)
	}
	d.Update(tea.WindowSizeMsg{Width: 80, Height: 22})
	d.Dispatch(tui.ChatExecuteCommandMsg{Name: "/effort"})

	// The keyboard alone moves the selection and commits it.
	d.Key(tea.KeyRight)
	if !strings.Contains(d.View(), "[high]") {
		t.Fatalf("right did not select high:\n%s", d.View())
	}
	committed, ok := d.Key(tea.KeyEnter).(tui.ChatExecuteCommandMsg)
	if !ok || committed.Name != "/effort" || committed.Args != "high" {
		t.Fatalf("enter did not commit the selected tier: %#v", committed)
	}
	d.Dispatch(committed)
	settled := d.View()
	if strings.Contains(settled, "Reasoning effort") {
		t.Fatalf("the selector stayed open after committing:\n%s", settled)
	}
	if !strings.Contains(settled, "reasoning effort set to high") || !strings.Contains(settled, "› ") {
		t.Fatalf("the daemon's answer did not reach the chat:\n%s", settled)
	}
	if d.App.ActiveSession.Effort != "high" {
		t.Fatalf("the chat kept effort %q", d.App.ActiveSession.Effort)
	}

	// The truth at the end is the daemon's session record.
	session := daemonSession(t, d.App.ActiveSession.ID)
	if session.Model != "o3-mini" || session.Effort != "high" {
		t.Fatalf("session %s kept model %q effort %q, want o3-mini at high", session.ID, session.Model, session.Effort)
	}
}
