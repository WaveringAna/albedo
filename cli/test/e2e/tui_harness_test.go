// Real-daemon TUI fixture: drives an AppModel directly through Bubble Tea
// update steps against the suite's shared daemon.
package e2e

import (
	"context"
	"reflect"
	"strings"
	"testing"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// tuiDriver drives a full tui.AppModel against the suite's real daemon,
// stepping Bubble Tea commands synchronously in place of the event loop.
type tuiDriver struct {
	t   *testing.T
	App tui.AppModel
}

// newTUIDriver opens a fresh daemon session in a temp workspace.
func newTUIDriver(t *testing.T) *tuiDriver {
	t.Helper()
	session := daemonSession(t, newSession(t, t.TempDir()))
	return driveTUI(t, &session)
}

// driveTUI boots an AppModel on session, or on the session picker when nil.
func driveTUI(t *testing.T, session *daemon.Session) *tuiDriver {
	workspace := t.TempDir()
	if session != nil {
		workspace = session.Workspace
	}
	d := &tuiDriver{t: t, App: tui.NewAppModel(conn(t), config.Profiles{}, session, workspace, false, nil)}
	d.Update(tea.WindowSizeMsg{Width: 80, Height: 22})
	return d
}

func daemonSessions(t *testing.T) []daemon.Session {
	t.Helper()
	sessions, err := daemon.Request[[]daemon.Session](context.Background(), conn(t), "/sessions", nil)
	if err != nil {
		t.Fatalf("list sessions: %v", err)
	}
	return sessions
}

func daemonSession(t *testing.T, id string) daemon.Session {
	t.Helper()
	for _, s := range daemonSessions(t) {
		if s.ID == id {
			return s
		}
	}
	t.Fatalf("the daemon does not list session %s", id)
	return daemon.Session{}
}

// Update feeds one message to the model and returns its command.
func (d *tuiDriver) Update(msg tea.Msg) tea.Cmd {
	d.t.Helper()
	updated, cmd := d.App.Update(msg)
	d.App = updated.(tui.AppModel)
	return cmd
}

// Send feeds msg to the model and returns what its command produced, or nil
// when the update returned no command.
func (d *tuiDriver) Send(msg tea.Msg) tea.Msg {
	d.t.Helper()
	results := d.results(d.Update(msg))
	if len(results) > 1 {
		d.t.Fatalf("expected one result, got %#v", results)
	}
	if len(results) == 0 {
		return nil
	}
	return results[0]
}

// Key presses code and returns what its command produced.
func (d *tuiDriver) Key(code rune) tea.Msg {
	d.t.Helper()
	return d.Send(tea.KeyPressMsg{Code: code})
}

// Dispatch feeds msg and every result it leads to back into the model until
// it settles; cursor blinks are dropped because nothing consumes them.
func (d *tuiDriver) Dispatch(msg tea.Msg) {
	d.t.Helper()
	queue := []tea.Msg{msg}
	for step := 0; len(queue) > 0; step++ {
		if step == 64 {
			d.t.Fatal("the model never settled")
		}
		msg, queue = queue[0], queue[1:]
		queue = append(queue, d.results(d.Update(msg))...)
	}
}

// results runs cmd and every command batched inside it.
func (d *tuiDriver) results(cmd tea.Cmd) []tea.Msg {
	if cmd == nil {
		return nil
	}
	switch msg := cmd().(type) {
	case nil:
		return nil
	case tea.BatchMsg:
		var all []tea.Msg
		for _, c := range msg {
			all = append(all, d.results(c)...)
		}
		return all
	default:
		if reflect.TypeOf(msg).PkgPath() == "charm.land/bubbles/v2/cursor" {
			return nil
		}
		return []tea.Msg{msg}
	}
}

// connected answers the chat's status poll once, as the event loop would
// before the composer lets a message through.
func (d *tuiDriver) connected() {
	d.t.Helper()
	chat := d.App.Chat
	d.Update(d.Update(tui.ChatStatusPollMsg{SessionID: chat.SessionID, Generation: chat.Generation})())
	if view := d.View(); strings.Contains(view, "connecting…") {
		d.t.Fatalf("the session still reads as connecting after its status answered:\n%s", view)
	}
}

// View returns the rendered terminal contents without styling.
func (d *tuiDriver) View() string {
	d.t.Helper()
	return ansi.Strip(d.App.View().Content)
}
