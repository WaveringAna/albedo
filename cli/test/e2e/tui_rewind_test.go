//go:build unix

// /tree rewinds the open session in place through the real daemon: the screen
// resets to what was kept, the removed message returns to the composer, and
// the rest waits in an archived session. A stubbed server cannot show the
// daemon stopping the session's actor and the chat hydrating from the new one.
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

func TestTreeRewindsTheOpenSessionAndReturnsTheMessage(t *testing.T) {
	profile := providerRoute(t, echoReply)
	t.Parallel()
	connection := conn(t)
	session, err := daemon.CreateSession(t.Context(), connection, daemon.CreateSessionRequest{Workspace: t.TempDir(), Provider: profile})
	if err != nil {
		t.Fatal(err)
	}
	client := daemon.NewChatClient(connection, session.ID)
	for index, prompt := range []string{"rewind first turn", "rewind second turn", "rewind third turn"} {
		if _, err := client.Send(t.Context(), prompt, nil); err != nil {
			t.Fatal(err)
		}
		waitIdle(t, session.ID, profile, index+1)
	}
	before := daemonSessions(t)

	d := driveTUIWithConnection(t, &session, connection)
	defer d.App.Chat.Close()
	d.Update(tea.WindowSizeMsg{Width: 100, Height: 40})
	d.Dispatch(tui.ChatOpenTreePickerMsg{})
	d.Type("second")
	d.Dispatch(tea.KeyPressMsg{Code: tea.KeyEnter})
	if view := d.View(); !strings.Contains(view, "Rewind to before") {
		t.Fatalf("enter did not ask before rewinding:\n%s", view)
	}

	// The second enter ends with the chat reopening on its stream, a read that
	// never returns by itself, so commands run side by side as the event loop
	// would run them.
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Second)
	defer cancel()
	inbox := make(chan tea.Msg, 32)
	streamMessages(ctx, d.Update(tea.KeyPressMsg{Code: tea.KeyEnter}), inbox)
	for view := ""; !strings.Contains(view, "archived as") || !strings.Contains(view, "rewind first turn"); view = d.View() {
		select {
		case msg := <-inbox:
			streamMessages(ctx, d.Update(msg), inbox)
		case <-ctx.Done():
			t.Fatalf("the rewound session never reappeared:\n%s", d.View())
		}
	}

	if d.App.ActiveSession == nil || d.App.ActiveSession.ID != session.ID {
		t.Fatalf("the rewind left the session: %+v", d.App.ActiveSession)
	}
	if got := d.App.Chat.TextArea.Value(); got != "rewind second turn" {
		t.Fatalf("the removed message did not return to the composer: %q", got)
	}
	view := d.View()
	if !strings.Contains(view, "rewind first turn") || strings.Contains(view, "rewind third turn") || !strings.Contains(view, "archived as") {
		t.Fatalf("the screen did not reset to what was kept:\n%s", view)
	}

	// The daemon kept the first turn in the session and the whole conversation
	// in one new archived session.
	preview, err := daemon.GetSessionPreview(t.Context(), connection, session.ID, 20)
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range preview.Items {
		if strings.Contains(item.Preview, "rewind second turn") || strings.Contains(item.Preview, "rewind third turn") {
			t.Fatalf("the session still holds %q", item.Preview)
		}
	}
	var added []daemon.Session
	for _, listed := range daemonSessions(t) {
		if !slices.ContainsFunc(before, func(s daemon.Session) bool { return s.ID == listed.ID }) {
			added = append(added, listed)
		}
	}
	archived := slices.IndexFunc(added, func(s daemon.Session) bool { return s.Archived && strings.HasPrefix(s.Title, "rewound: ") })
	if archived < 0 {
		t.Fatalf("no archived session holds the earlier conversation: %+v", added)
	}
	kept, err := daemon.GetSessionPreview(t.Context(), connection, added[archived].ID, 20)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.ContainsFunc(kept.Items, func(item daemon.PreviewItem) bool { return strings.Contains(item.Preview, "rewind third turn") }) {
		t.Fatalf("the archive lost the removed turns: %+v", kept)
	}
}
