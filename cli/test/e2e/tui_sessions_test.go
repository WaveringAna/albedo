//go:build unix

// Pinning, renaming, archiving and deleting cross the session picker, the
// prefs file and the daemon's PATCH and DELETE. A stubbed server cannot show
// the daemon keeping the new title or dropping the deleted session.
package e2e

import (
	"context"
	"slices"
	"strings"
	"testing"
	"time"

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

func TestTUINavigationRetainsPendingTurnsAndContinuation(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	released := false
	defer func() {
		if !released {
			close(release)
		}
	}()
	profile := providerRoute(t, func(request map[string]any) string {
		if lastUserText(request) == "active navigation turn" {
			close(entered)
			<-release
		}
		return echoReply(request)
	})
	session := daemonSession(t, newSession(t, t.TempDir()))
	other := daemonSession(t, newSession(t, t.TempDir()))
	if _, err := daemon.NewChatClient(conn(t), session.ID).Send(t.Context(), "active navigation turn", nil); err != nil {
		t.Fatal(err)
	}
	select {
	case <-entered:
	case <-time.After(10 * time.Second):
		t.Fatal("active turn did not start")
	}
	connection := daemon.NewConnection(conn(t).Snapshot(), nil)
	counter := &submissionCounterTransport{next: connection.HTTPClient().Transport, accepted: make(chan struct{})}
	connection.HTTPClient().Transport = counter
	t.Cleanup(connection.HTTPClient().CloseIdleConnections)
	driver := driveTUIWithConnection(t, &session, connection)
	t.Cleanup(func() { driver.App.Chat.Close() })
	driver.connected()
	submit := func(text string) tui.ChatTurnSentMsg {
		t.Helper()
		driver.App.Chat.TextArea.SetValue(text)
		var sent tui.ChatTurnSentMsg
		for _, message := range driver.results(driver.Update(tea.KeyPressMsg{Code: tea.KeyEnter})) {
			if admission, ok := message.(tui.ChatTurnSentMsg); ok {
				sent = admission
			}
			driver.Update(message)
		}
		if sent.Err != nil || sent.Handle == nil || !sent.OK {
			t.Fatalf("durable admission: %+v", sent)
		}
		return sent
	}
	pending := submit("waiting after navigation")
	continuation := submit(".")
	driver.Update(tui.FolderOpenSessionMsg{Session: other})
	seen := make(map[string]bool)
	for _, message := range driver.results(driver.Update(tui.FolderOpenSessionMsg{Session: session})) {
		if resolved, ok := message.(tui.ChatOperationResolvedMsg); ok {
			seen[resolved.Handle.ID()] = true
			if resolved.Err != nil || resolved.Receipt.DeliveryStatus != "pending" {
				t.Fatalf("reattached intent: %+v", resolved)
			}
		}
		driver.Update(message)
	}
	if !seen[pending.OperationID] || !seen[continuation.OperationID] || counter.posts.Load() != 2 {
		t.Fatal("navigation lost an intent or resubmitted it")
	}
	if !strings.Contains(driver.View(), "waiting after navigation") {
		t.Fatal("returning to the session lost its pending display")
	}
	close(release)
	released = true
	waitIdle(t, session.ID, profile, 2)
	driver.Update(tui.FolderOpenSessionMsg{Session: other})
	for _, message := range driver.results(driver.Update(tui.FolderOpenSessionMsg{Session: session})) {
		driver.Update(message)
	}
	history, err := daemon.NewChatClient(conn(t), session.ID).History(t.Context(), 0, 120)
	if err != nil {
		t.Fatal(err)
	}
	matched := 0
	for _, event := range history.Events {
		if event.Type == daemon.EventUser && event.OperationID == pending.OperationID {
			matched++
		}
		event.Replayed = true
		driver.Update(tui.ChatStreamEventMsg{SessionID: session.ID, Generation: driver.App.Chat.Generation, Event: event})
	}
	receipt, err := daemon.ResolveOperation(t.Context(), connection, continuation.Handle)
	if err != nil || receipt.DeliveryStatus != "committed" || matched != 1 || counter.posts.Load() != 2 {
		t.Fatalf("navigation delivery: matched=%d receipt=%+v err=%v posts=%d", matched, receipt, err, counter.posts.Load())
	}
}
