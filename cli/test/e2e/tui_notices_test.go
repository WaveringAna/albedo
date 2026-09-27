// Notices cross the session boundary and clear on a real submitted turn. A
// unit test with fabricated lifecycle messages cannot prove either daemon
// command.
package e2e

import (
	"strings"
	"testing"

	"albedo/cli/internal/tui"

	tea "charm.land/bubbletea/v2"
)

func TestTUINoticeMovesToANewSessionAndClearsOnSend(t *testing.T) {
	profile := providerRoute(t, echoReply)
	d := driveTUI(t, nil)
	const notice = "provider selected for new sessions"
	d.App.AddNotice(notice)
	// The created session's stream would block a synchronous walk, so only the
	// create command runs.
	d.Update(d.Update(tui.ChatNewSessionMsg{})())
	if d.App.ActiveSession == nil || !strings.Contains(d.View(), notice) {
		t.Fatalf("notice did not follow the real new session:\n%s", d.View())
	}

	// Enter batches the send with the spinner; only the send reaches the
	// daemon.
	d.App.Chat.TextArea.SetValue("clear the notice")
	batch, _ := d.Update(tea.KeyPressMsg{Code: tea.KeyEnter})().(tea.BatchMsg)
	for _, command := range batch {
		if msg, ok := command().(tui.ChatTurnSentMsg); ok {
			d.Update(msg)
		}
	}
	if len(d.App.Chat.Notices) != 0 || strings.Contains(d.View(), notice) {
		t.Fatalf("notice survived the submitted turn %v:\n%s", d.App.Chat.Notices, d.View())
	}
	waitIdle(t, d.App.ActiveSession.ID, profile, 1)
}
