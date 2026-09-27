// Effort selection crosses the composer, model registry, keyboard, and daemon
// session. Stubbed command replies cannot catch a dropped request or commit.
package e2e

import (
	"context"
	"strings"
	"testing"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestTUIEffortSelectorCommitsThroughTheDaemon(t *testing.T) {
	providerRoute(t, echoReply)
	id := newSession(t, t.TempDir())

	getSession := func() daemon.Session {
		t.Helper()
		sessions, err := daemon.Request[[]daemon.Session](context.Background(), conn(t), "/sessions", nil)
		if err != nil {
			t.Fatalf("list sessions: %v", err)
		}
		for _, session := range sessions {
			if session.ID == id {
				return session
			}
		}
		t.Fatalf("the daemon does not list session %s", id)
		return daemon.Session{}
	}
	session := getSession()

	app := tui.NewAppModel(conn(t), config.Profiles{}, &session, session.Workspace, false)
	updated, _ := app.Update(tea.WindowSizeMsg{Width: 80, Height: 22})
	app = updated.(tui.AppModel)

	// update feeds one message to the model; run executes the command the
	// model returned. Feeding every answer back, as the steps below do,
	// stands in for the Bubble Tea program loop. Each command on these paths
	// answers at once, so nothing here waits on a timer or a stream.
	update := func(msg tea.Msg) tea.Cmd {
		t.Helper()
		var cmd tea.Cmd
		updated, cmd = app.Update(msg)
		app = updated.(tui.AppModel)
		return cmd
	}
	run := func(cmd tea.Cmd) tea.Msg {
		t.Helper()
		if cmd == nil {
			t.Fatal("the update returned no command")
		}
		msg := cmd()
		if batch, ok := msg.(tea.BatchMsg); ok {
			if len(batch) != 1 {
				t.Fatalf("expected one command in the batch, got %d", len(batch))
			}
			msg = batch[0]()
		}
		return msg
	}
	view := func() string {
		t.Helper()
		return ansi.Strip(app.View().Content)
	}

	// Selecting a model goes through the real composer: enter dispatches the
	// command, the app asks the daemon, and the answer lands in the model.
	app.Chat.TextArea.SetValue("/model o3-mini")
	dispatched, ok := run(update(tea.KeyPressMsg{Code: tea.KeyEnter})).(tui.ChatExecuteCommandMsg)
	if !ok || dispatched.Name != "/model" || dispatched.Args != "o3-mini" {
		t.Fatalf("enter did not dispatch /model: %#v", dispatched)
	}
	update(run(update(dispatched)))
	if app.ActiveSession == nil || app.ActiveSession.Model != "o3-mini" || app.ActiveSession.Effort != "medium" {
		t.Fatalf("the daemon's model switch did not land: %+v", app.ActiveSession)
	}

	// /effort arrives as the message the command menu submits for it; the
	// daemon, not a stub, decides which tiers the model offers and which one
	// is current.
	update(run(update(tui.ChatExecuteCommandMsg{Name: "/effort"})))
	opened := view()
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

	// The keyboard alone moves the selection and commits it.
	update(tea.KeyPressMsg{Code: tea.KeyRight})
	if !strings.Contains(view(), "[high]") {
		t.Fatalf("right did not select high:\n%s", view())
	}
	committed, ok := run(update(tea.KeyPressMsg{Code: tea.KeyEnter})).(tui.ChatExecuteCommandMsg)
	if !ok || committed.Name != "/effort" || committed.Args != "high" {
		t.Fatalf("enter did not commit the selected tier: %#v", committed)
	}
	update(run(update(committed)))
	settled := view()
	if strings.Contains(settled, "Reasoning effort") {
		t.Fatalf("the selector stayed open after committing:\n%s", settled)
	}
	if !strings.Contains(settled, "reasoning effort set to high") || !strings.Contains(settled, "› ") {
		t.Fatalf("the daemon's answer did not reach the chat:\n%s", settled)
	}
	if app.ActiveSession.Effort != "high" {
		t.Fatalf("the chat kept effort %q", app.ActiveSession.Effort)
	}

	// The truth at the end is the daemon's session record.
	session = getSession()
	if session.Model != "o3-mini" || session.Effort != "high" {
		t.Fatalf("session %s kept model %q effort %q, want o3-mini at high", id, session.Model, session.Effort)
	}
}
