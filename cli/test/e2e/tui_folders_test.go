//go:build unix

// /cd crosses the composer, the folder picker, the daemon's /fs routes and
// its workspace move. A fake folder source cannot show the daemon listing a
// real directory, resolving a relative path, or keeping the new workspace.
package e2e

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"albedo/cli/internal/tui"

	tea "charm.land/bubbletea/v2"
)

func TestTUICdMovesTheSessionThroughThePicker(t *testing.T) {
	t.Parallel()
	providerRoute(t, echoReply)
	d := newTUIDriver(t)
	root := t.TempDir()
	for _, dir := range []string{"picked/src", "other", ".hidden"} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	d.Update(tea.WindowSizeMsg{Width: 120, Height: 30})
	same := func(got, want string) bool {
		g, _ := filepath.EvalSymlinks(got)
		w, _ := filepath.EvalSymlinks(want)
		return g == w
	}

	d.App.Chat.TextArea.SetValue("/cd")
	d.Dispatch(d.Key(tea.KeyEnter))
	if d.App.State != tui.AppStateFolderPicker {
		t.Fatalf("/cd did not open the picker:\n%s", d.View())
	}
	// The daemon lists the typed folder; the last segment filters it and
	// dot folders stay hidden.
	d.Type(root + "/pi")
	if view := d.View(); !strings.Contains(view, "picked") || strings.Contains(view, "other") || strings.Contains(view, ".hidden") {
		t.Fatalf("the listing was not filtered to picked:\n%s", view)
	}
	d.Dispatch(tea.KeyPressMsg{Code: tea.KeyEnter})
	if d.App.State != tui.AppStateChat {
		t.Fatalf("enter did not return to the chat:\n%s", d.View())
	}
	id := d.App.ActiveSession.ID
	if got := daemonSession(t, id).Workspace; !same(got, filepath.Join(root, "picked")) {
		t.Fatalf("the daemon kept workspace %q", got)
	}

	// /cd with a path moves at once, relative to where the session is.
	d.Dispatch(tui.ChatExecuteCommandMsg{Name: "/cd", Args: "../other"})
	if got := daemonSession(t, id).Workspace; !same(got, filepath.Join(root, "other")) || !same(d.App.Chat.Workspace, got) {
		t.Fatalf("/cd ../other left the daemon at %q and the chat at %q", got, d.App.Chat.Workspace)
	}
}

func TestTUIMissingWorkspaceSendsTheTurnFromThePickedFolder(t *testing.T) {
	t.Parallel()
	profile := providerRoute(t, echoReply)
	root := t.TempDir()
	gone, found := filepath.Join(root, "gone"), filepath.Join(root, "found")
	for _, dir := range []string{gone, found} {
		if err := os.Mkdir(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	session := daemonSession(t, newSession(t, gone))
	d := driveTUI(t, &session)
	d.Update(tea.WindowSizeMsg{Width: 120, Height: 30})
	if err := os.Remove(gone); err != nil {
		t.Fatal(err)
	}

	d.connected()
	d.App.Chat.TextArea.SetValue("hello from nowhere")
	d.Dispatch(tea.KeyPressMsg{Code: tea.KeyEnter})
	if view := d.View(); d.App.State != tui.AppStateFolderPicker || !strings.Contains(view, "not found") {
		t.Fatalf("a missing workspace did not open the picker:\n%s", view)
	}
	// Leaving the picker gives the refused turn back to the composer.
	d.Dispatch(tea.KeyPressMsg{Code: tea.KeyEscape})
	if got := d.App.Chat.TextArea.Value(); d.App.State != tui.AppStateChat || got != "hello from nowhere" {
		t.Fatalf("esc left state %v and composer %q", d.App.State, got)
	}
	d.Dispatch(tea.KeyPressMsg{Code: tea.KeyEnter})
	if d.App.State != tui.AppStateFolderPicker {
		t.Fatalf("sending again did not reopen the picker:\n%s", d.View())
	}
	d.Type(root + "/fou")
	// Settling would follow the turn's animation forever; one step sends it.
	moved, ok := d.Key(tea.KeyEnter).(tui.FolderMovedMsg)
	if !ok || moved.Err != nil {
		t.Fatalf("enter did not move the session: %#v", moved)
	}
	d.results(d.Update(moved))

	waitIdle(t, session.ID, profile, 1)
	requests := suite.provider.requests(profile)
	body, _ := requests[len(requests)-1]["body"].(map[string]any)
	if got := lastUserText(body); !strings.Contains(got, "hello from nowhere") {
		t.Fatalf("the refused turn was not sent again, the provider saw %q", got)
	}
	if got, _ := filepath.EvalSymlinks(daemonSession(t, session.ID).Workspace); got != mustEval(t, found) {
		t.Fatalf("the daemon kept workspace %q", got)
	}
}

func TestTUISessionsByFolderOpenAndStartSessions(t *testing.T) {
	t.Parallel()
	providerRoute(t, echoReply)
	root := t.TempDir()
	busy, empty, crowded := filepath.Join(root, "busy"), filepath.Join(root, "empty"), filepath.Join(root, "crowded")
	for _, dir := range []string{busy, empty, crowded} {
		if err := os.Mkdir(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	// A deep tree, taller than the pane, must not push the sessions off.
	for i := range 12 {
		for j := range 5 {
			if err := os.MkdirAll(filepath.Join(busy, fmt.Sprintf("d%02d/c%d", i, j)), 0o755); err != nil {
				t.Fatal(err)
			}
		}
	}
	there := newSession(t, busy)
	// In the sessions view the leading slash opens the folder browser, which
	// must be on screen before the rest of the path is typed into it.
	typePath := func(d *tuiDriver, path string) {
		d.Dispatch(tea.KeyPressMsg{Code: '/', Text: "/"})
		d.Type(strings.TrimPrefix(path, "/"))
	}

	// ^f in the sessions view browses folders; → steps into the highlighted
	// folder's sessions and enter opens one.
	d := driveTUI(t, nil)
	d.Update(tea.WindowSizeMsg{Width: 120, Height: 30})
	d.Dispatch(tea.KeyPressMsg{Code: 'f', Mod: tea.ModCtrl})
	if d.App.State != tui.AppStateFolderPicker {
		t.Fatalf("^f did not open the folder browser:\n%s", d.View())
	}
	d.Type(root + "/bu")
	if view := d.View(); !strings.Contains(view, "d00/") || !strings.Contains(view, "Untitled session") {
		t.Fatalf("the preview lost its tree or its sessions:\n%s", view)
	}
	d.Dispatch(tea.KeyPressMsg{Code: tea.KeyRight})
	opened, ok := d.Key(tea.KeyEnter).(tui.FolderOpenSessionMsg)
	if !ok || opened.Session.ID != there {
		t.Fatalf("enter in the folder's sessions did not open %s: %#v\n%s", there, opened, d.View())
	}
	d.Update(opened)
	if d.App.State != tui.AppStateChat || d.App.ActiveSession.ID != there {
		t.Fatalf("the picked session is not on screen:\n%s", d.View())
	}

	// Under a short tree the sessions fill the pane instead of a third of it.
	for range 12 {
		newSession(t, crowded)
	}
	d = driveTUI(t, nil)
	d.Update(tea.WindowSizeMsg{Width: 120, Height: 30})
	typePath(d, root+"/cr")
	if view := d.View(); strings.Count(view, "Untitled session") != 12 {
		t.Fatalf("the preview cut the sessions short:\n%s", view)
	}

	// A path typed into an empty search browses too, and enter on a folder
	// starts a session there.
	d = driveTUI(t, nil)
	d.Update(tea.WindowSizeMsg{Width: 120, Height: 30})
	typePath(d, root+"/em")
	if d.App.State != tui.AppStateFolderPicker {
		t.Fatalf("typing a path did not open the folder browser:\n%s", d.View())
	}
	started, ok := d.Key(tea.KeyEnter).(tui.FolderNewSessionMsg)
	if !ok {
		t.Fatalf("enter on a folder did not start a session: %#v", started)
	}
	d.Update(d.Send(started))
	if got := d.App.ActiveSession; d.App.State != tui.AppStateChat || got == nil || mustEval(t, got.Workspace) != mustEval(t, empty) {
		t.Fatalf("the new session is not in %s:\n%s", empty, d.View())
	}
}

func mustEval(t *testing.T, p string) string {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(p)
	if err != nil {
		t.Fatal(err)
	}
	return resolved
}
