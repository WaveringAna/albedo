//go:build unix

// Model and extension selection cross the composer, keyboard, and daemon
// session. Stubbed command replies cannot catch a dropped request or reload.
package e2e

import (
	"slices"
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestTUIEffortSelectorCommitsThroughTheDaemon(t *testing.T) {
	providerRoute(t, echoReply)
	session := daemonSession(t, newSession(t, t.TempDir()))
	if _, err := daemon.SelectModel(t.Context(), conn(t), session.ID, daemon.ModelSelectionRequest{Model: "o3", Effort: "high", ETag: session.ETag}); err != nil {
		t.Fatal(err)
	}
	session = daemonSession(t, session.ID)
	d := driveTUI(t, &session)

	// Selecting a model goes through the real composer: enter dispatches the
	// command, the app asks the daemon, and the answer lands in the model.
	d.App.Chat.TextArea.SetValue("/model o3-mini")
	dispatched, ok := d.Key(tea.KeyEnter).(tui.ChatExecuteCommandMsg)
	if !ok || dispatched.Name != "/model" || dispatched.Args != "o3-mini" {
		t.Fatalf("enter did not dispatch /model: %#v", dispatched)
	}
	d.Dispatch(dispatched)
	if d.App.ActiveSession == nil || d.App.ActiveSession.Model != "o3-mini" || d.App.ActiveSession.Effort != "high" {
		t.Fatalf("the daemon's model switch did not land:\n%s", d.View())
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
	if !strings.Contains(opened, "Reasoning effort") || !strings.Contains(opened, "[high]") {
		t.Fatalf("the daemon's current tier is not selected:\n%s", opened)
	}
	if strings.Contains(opened, "› ") {
		t.Fatal("the composer must be hidden while choosing effort")
	}

	// Even a narrow selector stays inside the terminal and Escape restores the
	// composer without changing the daemon.
	d.Update(tea.WindowSizeMsg{Width: 28, Height: 14})
	for line := range strings.SplitSeq(d.View(), "\n") {
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
	d.Key(tea.KeyLeft)
	if !strings.Contains(d.View(), "[medium]") {
		t.Fatalf("left did not select medium:\n%s", d.View())
	}
	committed, ok := d.Key(tea.KeyEnter).(tui.ChatExecuteCommandMsg)
	if !ok || committed.Name != "/effort" || committed.Args != "medium" {
		t.Fatalf("enter did not commit the selected tier: %#v", committed)
	}
	d.Dispatch(committed)
	settled := d.View()
	if strings.Contains(settled, "Reasoning effort") {
		t.Fatalf("the selector stayed open after committing:\n%s", settled)
	}
	if !strings.Contains(settled, "Effort saved.") || !strings.Contains(settled, "› ") {
		t.Fatalf("the daemon's answer did not reach the chat:\n%s", settled)
	}
	if d.App.ActiveSession.Effort != "medium" {
		t.Fatalf("the chat kept effort %q", d.App.ActiveSession.Effort)
	}

	// The truth at the end is the daemon's session record.
	session = daemonSession(t, d.App.ActiveSession.ID)
	if session.Model != "o3-mini" || session.Effort != "medium" {
		t.Fatalf("session %s kept model %q effort %q, want o3-mini at medium", session.ID, session.Model, session.Effort)
	}
}

// Every prompt retitles the session. The chat keeps the configuration it
// observed before that, so a retitle must not make /effort a conflict.
func TestTUIEffortAfterAPromptRetitlesTheSession(t *testing.T) {
	profile := providerRoute(t, echoReply)
	session := daemonSession(t, newSession(t, t.TempDir()))
	if _, err := daemon.SelectModel(t.Context(), conn(t), session.ID, daemon.ModelSelectionRequest{Model: "o3", Effort: "low", ETag: session.ETag}); err != nil {
		t.Fatal(err)
	}
	session = daemonSession(t, session.ID)
	d := driveTUI(t, &session)
	defer d.App.Chat.Close()
	if _, err := daemon.NewChatClient(conn(t), session.ID).Send(t.Context(), "a prompt that names the session", nil); err != nil {
		t.Fatal(err)
	}
	waitIdle(t, session.ID, profile, 1)
	if retitled := daemonSession(t, session.ID); retitled.Title == session.Title {
		t.Fatalf("the prompt kept the title %q", retitled.Title)
	}

	d.Dispatch(tui.ChatExecuteCommandMsg{Name: "/effort", Args: "high"})
	if view := d.View(); !strings.Contains(view, "Effort saved.") {
		t.Fatalf("/effort after a prompt failed:\n%s", view)
	}
	if session := daemonSession(t, session.ID); session.Effort != "high" {
		t.Fatalf("session kept effort %q, want high", session.Effort)
	}
}

// Text after a command that declares no arguments is a prompt that starts with
// the command's name; the command would only reject it.
func TestTUISendsTextAfterAnArgumentlessCommandAsAPrompt(t *testing.T) {
	profile := providerRoute(t, echoReply)
	t.Parallel()
	session := daemonSession(t, newSession(t, t.TempDir()))
	// A session lists its commands once its first turn has loaded them.
	if _, err := daemon.NewChatClient(conn(t), session.ID).Send(t.Context(), "hello", nil); err != nil {
		t.Fatal(err)
	}
	waitIdle(t, session.ID, profile, 1)
	d := driveTUI(t, &session)
	defer d.App.Chat.Close()
	d.Dispatch(tui.CapabilityPageChangedMsg{})
	jobs := slices.IndexFunc(d.App.Chat.CommandMenu.Catalog, func(command daemon.SessionCommand) bool { return command.Name == "/jobs" })
	if jobs < 0 || len(d.App.Chat.CommandMenu.Catalog[jobs].Arguments) != 0 {
		t.Fatalf("the daemon's catalog has no argumentless /jobs: %+v", d.App.Chat.CommandMenu.Catalog)
	}
	d.connected()

	d.App.Chat.TextArea.SetValue("/jobs is broken")
	var admitted tui.ChatTurnSentMsg
	for _, message := range d.results(d.Update(tea.KeyPressMsg{Code: tea.KeyEnter})) {
		if sent, ok := message.(tui.ChatTurnSentMsg); ok {
			admitted = sent
			d.Update(sent)
		}
	}
	if admitted.Err != nil || !admitted.OK {
		t.Fatalf("enter did not send the prompt: %+v\n%s", admitted, d.View())
	}
	waitIdle(t, session.ID, profile, 2)
	if reply := strings.Join(eventText(durableHistorySnapshot(t, session.ID), "message"), "\n"); !strings.Contains(reply, "echo: /jobs is broken") {
		t.Fatalf("the model did not receive the whole prompt; got:\n%s", reply)
	}
}

func TestTUIExtensionPickerSwitchesCompactionStrategies(t *testing.T) {
	profile := providerRoute(t, echoReply)
	t.Parallel()
	session := daemonSession(t, newSession(t, t.TempDir()))
	d := driveTUI(t, &session)
	defer d.App.Chat.Close()
	for turn, name := range []string{"lcm", "rolling", "lcm"} {
		d.Dispatch(tui.ChatExecuteCommandMsg{Name: "/extensions"})
		d.Dispatch(tea.KeyPressMsg{Code: 's', Text: "s"})
		picker := d.App.ExtensionPicker
		index := -1
		for i, item := range picker.Extensions {
			if item.Name == name {
				index = i
				if item.Enabled {
					t.Fatalf("strategy %s is already enabled before its switch", name)
				}
			}
		}
		if index < 0 {
			t.Fatalf("strategy %s is missing from the actual extension picker", name)
		}
		for d.App.ExtensionPicker.Cursor < index {
			d.Dispatch(tea.KeyPressMsg{Code: tea.KeyDown})
		}
		for d.App.ExtensionPicker.Cursor > index {
			d.Dispatch(tea.KeyPressMsg{Code: tea.KeyUp})
		}
		d.Dispatch(tea.KeyPressMsg{Code: tea.KeyEnter})
		d.Dispatch(tea.KeyPressMsg{Code: tea.KeyEnter})
		if picker := d.App.ExtensionPicker; picker.Error != "" || picker.Confirming || !strings.Contains(picker.Notice, "Reload completed.") {
			t.Fatalf("strategy %s did not apply through the picker:\n%s", name, d.View())
		}
		configuration, err := daemon.GetSessionConfiguration(t.Context(), conn(t), session.ID)
		if err != nil {
			t.Fatal(err)
		}
		for _, strategy := range []string{"lcm", "rolling"} {
			chosen := configuration.Value.Selection.Extensions[strategy]
			if enabled := chosen != nil && *chosen; enabled != (strategy == name) {
				t.Fatalf("single %s toggle left competing selection %+v", name, configuration.Value.Selection.Extensions)
			}
		}
		client := daemon.NewChatClient(conn(t), session.ID)
		if _, err := client.Send(t.Context(), "use the selected strategy", nil); err != nil {
			t.Fatal(err)
		}
		waitIdle(t, session.ID, profile, turn+1)
		prepared, err := daemon.GetContextSnapshot(t.Context(), conn(t), session.ID)
		if err != nil || prepared.State != "ready" || prepared.Compaction.Strategy != name {
			t.Fatalf("turn did not use selected strategy %s: %+v, %v", name, prepared, err)
		}
		if turn == 0 {
			current := daemonSession(t, session.ID)
			if _, err := daemon.RenameSession(t.Context(), conn(t), session.ID, "strategy review", current.ETag); err != nil {
				t.Fatal(err)
			}
			// Another client edited this session while the picker was open.
			// A stale confirmation refreshes the choices without replaying it.
			d.Dispatch(tea.KeyPressMsg{Code: tea.KeyEnter})
			d.Dispatch(tea.KeyPressMsg{Code: tea.KeyEnter})
			picker := d.App.ExtensionPicker
			if picker.Loading || picker.Saving || picker.Confirming || picker.Error != "" || !strings.Contains(picker.Notice, "Review the refreshed choices") {
				t.Fatalf("stale selection did not return to review:\n%s", d.View())
			}
			configuration, err := daemon.GetSessionConfiguration(t.Context(), conn(t), session.ID)
			if err != nil || configuration.Value.Selection.Extensions[name] == nil || !*configuration.Value.Selection.Extensions[name] {
				t.Fatalf("stale confirmation changed the saved strategy: %+v, %v", configuration, err)
			}
		}
		d.Dispatch(tea.KeyPressMsg{Code: tea.KeyEscape})
	}
}
