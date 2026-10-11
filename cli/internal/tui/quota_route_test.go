package tui

import (
	"albedo/cli/internal/daemon"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func dispatchCmd(app *AppModel, cmd tea.Cmd) *AppModel {
	if cmd == nil {
		return app
	}
	msg := cmd()
	if batch, ok := msg.(tea.BatchMsg); ok {
		for _, sub := range batch {
			if sub != nil {
				app = dispatchCmd(app, sub)
			}
		}
		return app
	}
	if msg != nil {
		updated, next := app.Update(msg)
		app = updated.(*AppModel)
		if next != nil {
			app = dispatchCmd(app, next)
		}
	}
	return app
}

func newTestApp(t *testing.T) *AppModel {
	t.Helper()
	conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, nil)
	session := &daemon.Session{ID: "test-session", Model: "test-model"}
	app := NewAppModel(conn, Bootstrap{}, session, "", false, nil)
	t.Cleanup(app.Chat.Close)
	app.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	return app
}

func TestQuotaRouteFromChat(t *testing.T) {
	app := newTestApp(t)
	if app.State != AppStateChat {
		t.Fatalf("expected initial state AppStateChat, got %v", app.State)
	}

	app.Chat.TextArea.SetValue("/quota")
	updated, cmd := app.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	app = updated.(*AppModel)
	app = dispatchCmd(app, cmd)

	if app.State != AppStateQuota {
		t.Fatalf("submitting /quota should reach AppStateQuota, got %v", app.State)
	}

	view := ansi.Strip(app.View().Content)
	if !strings.Contains(view, "/quota") {
		t.Fatalf("view should contain /quota title, got:\n%s", view)
	}
}

func TestQuotaRouteEscapeReturnsToChat(t *testing.T) {
	app := newTestApp(t)
	app.Chat.TextArea.SetValue("/quota")
	updated, cmd := app.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	app = updated.(*AppModel)
	app = dispatchCmd(app, cmd)

	if app.State != AppStateQuota {
		t.Fatalf("failed to enter AppStateQuota: %v", app.State)
	}

	updated, cmd = app.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	app = updated.(*AppModel)
	app = dispatchCmd(app, cmd)

	if app.State != AppStateChat {
		t.Fatalf("esc from quota screen should return to AppStateChat, got %v", app.State)
	}
}

func TestQuotaRouteWindowResize(t *testing.T) {
	app := newTestApp(t)
	app.Chat.TextArea.SetValue("/quota")
	updated, cmd := app.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	app = updated.(*AppModel)
	app = dispatchCmd(app, cmd)

	if app.State != AppStateQuota {
		t.Fatalf("failed to enter AppStateQuota: %v", app.State)
	}

	updated, _ = app.Update(tea.WindowSizeMsg{Width: 120, Height: 45})
	app = updated.(*AppModel)

	if app.Quota.Width != 120 || app.Quota.Height != 45 {
		t.Fatalf("window resize did not resize QuotaModel: got (%d, %d), want (120, 45)", app.Quota.Width, app.Quota.Height)
	}
}

func TestQuotaRouteStaleGenerationIgnored(t *testing.T) {
	app := newTestApp(t)
	app.Chat.TextArea.SetValue("/quota")
	updated, cmd := app.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	app = updated.(*AppModel)
	app = dispatchCmd(app, cmd)

	if app.State != AppStateQuota {
		t.Fatalf("failed to enter AppStateQuota: %v", app.State)
	}

	currentGen := app.Quota.Generation
	staleGen := currentGen - 1
	reading := daemon.QuotaObservation{
		Provider:  "test-provider",
		AccountID: "test-account",
		LimitID:   "test-limit",
		Label:     "Test Limit",
	}

	// Send stale generation reply
	updated, _ = app.Update(quotaLoadedMsg{
		Gen:      staleGen,
		Readings: []daemon.QuotaObservation{reading},
	})
	app = updated.(*AppModel)

	if len(app.Quota.readings) != 0 {
		t.Fatalf("stale generation reply modified Quota.readings: got %d readings, want 0", len(app.Quota.readings))
	}

	// Send matching generation reply
	updated, _ = app.Update(quotaLoadedMsg{
		Gen:      currentGen,
		Readings: []daemon.QuotaObservation{reading},
	})
	app = updated.(*AppModel)

	if len(app.Quota.readings) != 1 {
		t.Fatalf("valid generation reply did not populate Quota.readings: got %d readings, want 1", len(app.Quota.readings))
	}

	// Send another stale reply with empty readings; it must not overwrite the existing reading
	updated, _ = app.Update(quotaLoadedMsg{
		Gen:      staleGen,
		Readings: []daemon.QuotaObservation{},
	})
	app = updated.(*AppModel)

	if len(app.Quota.readings) != 1 {
		t.Fatalf("stale generation reply cleared existing Quota.readings: got %d readings, want 1", len(app.Quota.readings))
	}
}
