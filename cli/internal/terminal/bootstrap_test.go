// Count requests across preparation and TUI initialization, including notice
// acknowledgements. Daemon E2E cannot inspect the detached UI's startup commands.
package terminal

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"albedo/cli/internal/app"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/testwire"
	"albedo/cli/internal/tui"
	tea "charm.land/bubbletea/v2"
)

func runInitialCommands(model tea.Model, command tea.Cmd) {
	if command == nil {
		return
	}
	msg := command()
	if batch, ok := msg.(tea.BatchMsg); ok {
		for _, child := range batch {
			runInitialCommands(model, child)
		}
		return
	}
	// Follow-up commands include recurring UI timers and stream subscriptions.
	_, _ = model.Update(msg)
}

func TestPreparedStartupReusesReadsAndRefreshesNoticeValidator(t *testing.T) {
	for _, scenario := range []struct {
		name                           string
		selected, fresh, login, notice bool
	}{
		{name: "picker"},
		{name: "acknowledged notice", notice: true},
		{name: "resume", selected: true},
		{name: "fresh", fresh: true},
		{name: "login", login: true},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			settingsReads, sessionLists := 0, 0
			acknowledged := false
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch {
				case r.URL.Path == "/server":
					var resource map[string]any
					_ = json.Unmarshal([]byte(testwire.Server), &resource)
					if scenario.notice {
						resource["notices"] = []any{map[string]any{"id": "migration", "kind": "migration", "message": "Updated settings"}}
					}
					_ = json.NewEncoder(w).Encode(resource)
				case r.URL.Path == "/sessions":
					sessionLists++
					items := []any{}
					if !scenario.login {
						items = append(items, testwire.Session("existing", testwire.GenerationA, 0))
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"items": items, "next": nil})
				case strings.HasPrefix(r.URL.Path, "/sessions/"):
					id := strings.TrimPrefix(r.URL.Path, "/sessions/")
					if r.Method == http.MethodPut {
						w.WriteHeader(http.StatusCreated)
					}
					_ = json.NewEncoder(w).Encode(testwire.Session(id, testwire.GenerationA, 0))
				case r.URL.Path == "/settings":
					settings := testwire.Settings()
					if !scenario.login {
						settings["providers"].(map[string]any)["default_profile"] = "work"
					}
					ui := settings["ui"].(map[string]any)
					if r.Method == http.MethodPatch {
						if r.Header.Get("If-Match") != `"ui-a"` {
							t.Errorf("notice acknowledgement used stale validator: %s", r.Header.Get("If-Match"))
						}
						acknowledged = true
						ui["dismissed_notices"] = []any{"migration"}
						_ = json.NewEncoder(w).Encode(testwire.SettingsChange("ui", ui))
						return
					}
					settingsReads++
					if acknowledged {
						ui["dismissed_notices"] = []any{"migration"}
						settings["group_resources"].(map[string]any)["ui"].(map[string]any)["etag"] = `"ui-b"`
					}
					_ = json.NewEncoder(w).Encode(settings)
				case r.URL.Path == "/auth":
					_, _ = io.WriteString(w, `{"providers":[],"accounts":[]}`)
				default:
					t.Errorf("unexpected startup request: %s %s", r.Method, r.URL)
					http.NotFound(w, r)
				}
			}))
			t.Cleanup(server.Close)
			conn, err := daemon.Attach(t.Context(), daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "token"}, nil)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(conn.HTTPClient().CloseIdleConnections)
			workflow := app.Service{Connect: func(_ context.Context) (*daemon.Connection, error) { return conn, nil }}
			options := app.OpenOptions{Terminal: true, Fresh: scenario.fresh}
			if scenario.selected {
				options.SessionID = "existing"
			}
			prepared, err := workflow.PrepareOpen(t.Context(), options)
			if err != nil {
				t.Fatal(err)
			}
			service := Service{In: strings.NewReader("\n"), Out: io.Discard}
			settings, err := service.announceMigration(t.Context(), conn, prepared.Settings)
			if err != nil {
				t.Fatal(err)
			}
			model := tui.NewAppModel(conn, tui.Bootstrap{Sessions: prepared.Sessions, Settings: settings}, prepared.Selected, prepared.Workspace, prepared.LoginRequired, nil)
			t.Cleanup(func() { _ = model.Close() })
			if scenario.selected || scenario.fresh {
				if model.ActiveSession == nil || !model.Chat.Flags.Thinking || model.Chat.Flags.Tools {
					t.Fatal("chat did not start from prepared preferences")
				}
				found := false
				for _, session := range model.Sessions {
					found = found || session.ID == model.ActiveSession.ID && session.ETag != ""
				}
				if !found {
					t.Fatal("selected or created session missing from bootstrap")
				}
			} else {
				runInitialCommands(model, model.Init())
				if model.SessionPicker.Loading || len(model.Sessions) != len(prepared.Sessions) {
					t.Fatal("prepared list was discarded, including its known empty state")
				}
			}
			wantSettings := 1
			if scenario.notice {
				wantSettings++
				if model.UI.ETag != `"ui-b"` || len(model.UI.DismissedNotices) != 1 {
					t.Fatalf("TUI seeded before notice acknowledgement: %+v", model.UI)
				}
			}
			if sessionLists != 1 || settingsReads != wantSettings {
				t.Fatalf("startup read sessions %d times and settings %d times, want 1 and %d", sessionLists, settingsReads, wantSettings)
			}
		})
	}
}
