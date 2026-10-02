// A confirmed model switch must survive its following cap failure. Controlled
// partial responses and stale deliveries cannot be produced deterministically
// by the healthy daemon, so these tests isolate the UI state transition.
package tui

import (
	"errors"
	"net/http"
	"testing"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
)

func TestModelChangeRetainsConfirmedSelectionWhenCapFails(t *testing.T) {
	for _, status := range []int{http.StatusBadRequest, http.StatusOK} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			requests := 0
			conn := commandTestConnection(t, func(w http.ResponseWriter, _ *http.Request) {
				requests++
				if requests == 1 {
					_, _ = w.Write([]byte(`{"result":{"model":"confirmed","provider":"provider","protocol":"openai","effort":null}}`))
					return
				}
				w.WriteHeader(status)
				_, _ = w.Write([]byte(`{}`))
			})
			session := &daemon.Session{ID: "session", Model: "old", Provider: "old-provider", Effort: "high"}
			app := NewAppModel(conn, config.Profiles{}, session, "", false, nil)
			t.Cleanup(app.Chat.Close)
			app.State, app.ModelPicker.Saving, app.ModelGen = AppStateModelPicker, true, 1
			raise := true
			msg := app.changeModelCmd("requested", "", "", &raise, app.ModelGen)().(modelChangedMsg)
			if msg.Err == nil || msg.Selection == nil {
				t.Fatalf("lost confirmed switch or following failure: %+v", msg)
			}
			if status == http.StatusOK {
				var uncertain *daemon.UncertainOutcomeError
				var protocol *daemon.ProtocolError
				if !errors.As(msg.Err, &uncertain) || !errors.As(msg.Err, &protocol) {
					t.Fatalf("invalid cap response lost typed uncertainty: %v", msg.Err)
				}
			}
			updated, cmd := app.Update(msg)
			app = updated.(AppModel)
			if cmd != nil || requests != 2 {
				t.Fatalf("cap failure caused another operation: requests=%d command=%v", requests, cmd != nil)
			}
			if app.ActiveSession.Model != "confirmed" || app.Chat.Model != "confirmed" || app.ActiveSession.Provider != "provider" || app.Chat.Provider != "provider" || app.ActiveSession.Protocol != "openai" || app.ActiveSession.Effort != "" || app.Chat.Effort != "" {
				t.Fatalf("did not apply confirmed switch: %+v", app.ActiveSession)
			}
			if app.State != AppStateChat || app.ModelPicker.Saving || len(app.Chat.Notices) != 1 {
				t.Fatal("confirmed switch did not settle picker and surface the cap failure")
			}
		})
	}
}

func TestModelChangeFailureDoesNotApplySelectionOrRaiseCap(t *testing.T) {
	for _, status := range []int{http.StatusBadRequest, http.StatusOK} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			requests := 0
			conn := commandTestConnection(t, func(w http.ResponseWriter, _ *http.Request) {
				requests++
				w.WriteHeader(status)
				_, _ = w.Write([]byte(`{}`))
			})
			session := &daemon.Session{ID: "session", Model: "old", Provider: "provider", Effort: "low"}
			app := NewAppModel(conn, config.Profiles{}, session, "", false, nil)
			t.Cleanup(app.Chat.Close)
			app.State, app.ModelPicker.Saving, app.ModelGen = AppStateModelPicker, true, 1
			raise := true
			msg := app.changeModelCmd("requested", "", "", &raise, app.ModelGen)().(modelChangedMsg)
			updated, cmd := app.Update(msg)
			app = updated.(AppModel)
			if msg.Err == nil || msg.Selection != nil || requests != 1 || cmd != nil {
				t.Fatalf("failed switch proceeded to cap or invented confirmation: %+v requests=%d", msg, requests)
			}
			if app.ActiveSession.Model != "old" || app.Chat.Model != "old" || app.ActiveSession.Effort != "low" || app.Chat.Effort != "low" || app.State != AppStateModelPicker || app.ModelPicker.Saving || app.ModelPicker.Error == "" {
				t.Fatal("failed switch changed confirmed state or failed to settle picker")
			}
		})
	}
}

func TestModelChangeIgnoresStaleSessionOrGeneration(t *testing.T) {
	for _, scenario := range []struct {
		name, sessionID string
		generation      int
	}{
		{"session", "other", 1},
		{"generation", "session", 0},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			app := NewAppModel(daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, nil), config.Profiles{}, &daemon.Session{ID: "session", Model: "old"}, "", false, nil)
			t.Cleanup(app.Chat.Close)
			app.State, app.ModelPicker.Saving, app.ModelGen = AppStateModelPicker, true, 1
			updated, cmd := app.Update(modelChangedMsg{
				Selection: &daemon.ModelSelection{Model: "stale"},
				Err:       errors.New("stale failure"), SessionID: scenario.sessionID, Gen: scenario.generation,
			})
			app = updated.(AppModel)
			if cmd != nil || app.ActiveSession.Model != "old" || app.Chat.Model != "old" || app.State != AppStateModelPicker || !app.ModelPicker.Saving || app.ModelPicker.Error != "" || len(app.Chat.Notices) != 0 {
				t.Fatal("stale result changed current session, picker, or notices")
			}
		})
	}
}

func TestModelChangePreservesScreenAfterLeavingPicker(t *testing.T) {
	app := NewAppModel(daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, nil), config.Profiles{}, &daemon.Session{ID: "session", Model: "old"}, "", false, nil)
	t.Cleanup(app.Chat.Close)
	app.State, app.ModelGen = AppStateSessionPicker, 1
	updated, cmd := app.Update(modelChangedMsg{
		Selection: &daemon.ModelSelection{Model: "confirmed"}, SessionID: "session", Gen: 1,
	})
	app = updated.(AppModel)
	if cmd != nil || app.ActiveSession.Model != "confirmed" || app.Chat.Model != "confirmed" || app.State != AppStateSessionPicker {
		t.Fatal("confirmed switch failed to update its session or changed an unrelated screen")
	}
}
