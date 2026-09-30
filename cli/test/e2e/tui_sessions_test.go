// Pinning, renaming, archiving and deleting cross the session picker, the
// prefs file and the daemon's PATCH and DELETE. A stubbed server cannot show
// the daemon keeping the new title or dropping the deleted session.
package e2e

import (
	"context"
	"slices"
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui"

	tea "charm.land/bubbletea/v2"
)

func TestTUISessionPickerPinsRenamesArchivesAndDeletes(t *testing.T) {
	t.Parallel()
	providerRoute(t, echoReply)
	d := newTUIDriver(t)
	target := newSession(t, t.TempDir())
	d.Dispatch(tui.ChatBackToSessionsMsg{})
	// highlight puts the picker cursor on id; the actions themselves are keys.
	highlight := func(id string) {
		t.Helper()
		i := slices.IndexFunc(d.App.SessionPicker.Filtered, func(it tui.PickerItem) bool { return it.ID == id })
		if i < 0 {
			t.Fatalf("the picker does not list %s:\n%s", id, d.View())
		}
		d.App.SessionPicker.Cursor = i
	}
	ctrl := func(code rune) { d.Dispatch(tea.KeyPressMsg{Code: code, Mod: tea.ModCtrl}) }

	highlight(target)
	ctrl('s')
	saved, err := daemon.GetSettings(context.Background(), conn(t))
	if err != nil || !slices.Contains(saved.UI.Pinned, target) || !strings.Contains(d.View(), "pinned 1") {
		t.Fatalf("ctrl+s did not pin %s (prefs %+v, %v):\n%s", target, saved.UI, err, d.View())
	}

	ctrl('r')
	for _, r := range "renamed-session" {
		d.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	d.Dispatch(tea.KeyPressMsg{Code: tea.KeyEnter})
	if title := daemonSession(t, target).Title; title != "renamed-session" || !strings.Contains(d.View(), "renamed-session") {
		t.Fatalf("the daemon kept title %q:\n%s", title, d.View())
	}

	ctrl('a')
	highlight("archive")
	d.Dispatch(tea.KeyPressMsg{Code: tea.KeyEnter})
	highlight(target)
	ctrl('d')
	d.Dispatch(tea.KeyPressMsg{Code: 'y', Text: "y"})
	if slices.ContainsFunc(daemonSessions(t), func(s daemon.Session) bool { return s.ID == target }) {
		t.Fatalf("the daemon still lists deleted session %s", target)
	}
}
