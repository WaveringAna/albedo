//go:build unix

// /quota crosses the composer, the quota screen, the client's read of the
// daemon's /server route and the daemon's own answer. A fixed Server fixture
// cannot show the client decoding what the daemon really sends: a hermetic
// daemon has no accounts to poll, so the screen must say so and still leave.
package e2e

import (
	"strings"
	"testing"

	"albedo/cli/internal/tui"

	tea "charm.land/bubbletea/v2"
)

func TestTUIQuotaOpensOnTheDaemonsReadingsAndLeaves(t *testing.T) {
	providerRoute(t, echoReply)
	t.Parallel()
	d := newTUIDriver(t)
	d.Update(tea.WindowSizeMsg{Width: 120, Height: 30})

	d.App.Chat.TextArea.SetValue("/quota")
	d.Dispatch(tea.KeyPressMsg{Code: tea.KeyEnter})
	if d.App.State != tui.AppStateQuota {
		t.Fatalf("/quota did not open the quota screen:\n%s", d.View())
	}
	if d.App.Quota.Loading || d.App.Quota.Error != "" {
		t.Fatalf("the quota read did not settle (loading %v, error %q):\n%s", d.App.Quota.Loading, d.App.Quota.Error, d.View())
	}
	if view := d.View(); !strings.Contains(view, "No quota readings yet") {
		t.Fatalf("a daemon with no accounts should say there are no readings:\n%s", view)
	}

	d.Dispatch(tea.KeyPressMsg{Code: tea.KeyEscape})
	if d.App.State != tui.AppStateChat {
		t.Fatalf("esc did not return to the chat:\n%s", d.View())
	}
}
