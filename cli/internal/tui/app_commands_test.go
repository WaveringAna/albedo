// Background commands must retain their inputs across UI changes. Daemon E2E
// tests cannot control the interval between command creation and execution.
package tui

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sync"
	"testing"
	"time"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
)

func commandTestConnection(t *testing.T, handler http.HandlerFunc) *daemon.Connection {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	return daemon.NewConnection(daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
}

func awaitCommandSignal[T any](t *testing.T, ch <-chan T) T {
	t.Helper()
	select {
	case value := <-ch:
		return value
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for background command")
		var zero T
		return zero
	}
}

func TestModelChangeCapturesProviderAndCapBeforeExecution(t *testing.T) {
	for _, scenario := range []struct {
		name                string
		failSwitch          bool
		failCap             bool
		unsupportedProvider bool
	}{
		{name: "success"},
		{name: "provider unsupported", unsupportedProvider: true},
		{name: "switch fails", failSwitch: true},
		{name: "cap fails", failCap: true},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			var paths, names, capStates, capModels []string
			var modelArgs map[string]string
			conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/health" {
					if scenario.unsupportedProvider {
						_, _ = w.Write([]byte(`{"ok":true,"version":2,"capabilities":[]}`))
					} else {
						_, _ = w.Write([]byte(`{"ok":true,"version":2,"capabilities":["session_provider"]}`))
					}
					return
				}
				var body struct {
					Name string            `json:"name"`
					Args map[string]string `json:"args"`
				}
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Error(err)
				}
				paths = append(paths, r.URL.Path)
				names = append(names, body.Name)
				if body.Name == "/model" {
					modelArgs = body.Args
				}
				if body.Name == "/raise-cap" {
					capStates = append(capStates, body.Args["state"])
					capModels = append(capModels, body.Args["model"])
				}
				if body.Name == "/model" && scenario.failSwitch || body.Name == "/raise-cap" && scenario.failCap {
					http.Error(w, `{"error":"refused"}`, http.StatusBadRequest)
					return
				}
				_, _ = w.Write([]byte(`{"result":{"model":"resolved","provider":"new","protocol":"openai","effort":"high"}}`))
			})
			session := &daemon.Session{ID: "original", Provider: "old"}
			app := AppModel{Conn: conn, ActiveSession: session}
			raiseCap := true
			cmd := app.changeModelCmd("chosen", "new", "high", &raiseCap, 7)
			session.ID, session.Provider = "changed", "new"
			raiseCap = false
			app.Conn, app.ActiveSession, app.ModelGen = nil, nil, 8
			msg := cmd().(modelChangedMsg)
			if msg.Gen != 7 || msg.SessionID != "original" || (msg.Err != nil) != (scenario.failSwitch || scenario.failCap || scenario.unsupportedProvider) {
				t.Fatalf("unexpected model result: %+v", msg)
			}
			if scenario.unsupportedProvider {
				if len(names) != 0 || msg.Selection != nil {
					t.Fatalf("unsupported provider dispatched mutation: names=%v result=%+v", names, msg)
				}
				return
			}
			if !reflect.DeepEqual(modelArgs, map[string]string{"model": "chosen", "provider": "new", "effort": "high"}) {
				t.Fatalf("model request used changed inputs: %v", modelArgs)
			}
			if scenario.failSwitch {
				if msg.Selection != nil {
					t.Fatalf("failed switch installed selection: %+v", msg.Selection)
				}
			} else if msg.Selection == nil || msg.Selection.Model != "resolved" {
				t.Fatalf("confirmed switch was lost: %+v", msg)
			}
			wantNames := []string{"/model", "/raise-cap"}
			wantPaths := []string{"/sessions/original/commands", "/sessions/original/commands"}
			if scenario.failSwitch {
				wantNames, wantPaths = wantNames[:1], wantPaths[:1]
			} else if !reflect.DeepEqual(capStates, []string{"on"}) || !reflect.DeepEqual(capModels, []string{"resolved"}) {
				t.Fatalf("cap used changed input or unconfirmed model: state=%v model=%v", capStates, capModels)
			}
			if !reflect.DeepEqual(names, wantNames) || !reflect.DeepEqual(paths, wantPaths) {
				t.Fatalf("requests changed target or order: paths=%v commands=%v", paths, names)
			}
		})
	}
}

func TestSessionCommandKeepsSessionWhileRequestIsRunning(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	releaseRequest := func() { releaseOnce.Do(func() { close(release) }) }
	conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/sessions/original/commands" {
			t.Errorf("request targeted %s", r.URL.Path)
		}
		close(started)
		<-release
		_, _ = w.Write([]byte(`{"result":{"effort":null,"message":"","available":["low","high"]}}`))
	})
	// Release the handler before the server cleanup, including on test failure.
	t.Cleanup(releaseRequest)
	session := &daemon.Session{ID: "original"}
	app := AppModel{Conn: conn, ActiveSession: session}
	cmd := app.executeCommandCmd("/effort", "", 9)
	done := make(chan tea.Msg, 1)
	go func() { done <- cmd() }()
	awaitCommandSignal(t, started)
	session.ID = "changed"
	app.ActiveSession, app.Conn, app.CommandGen = nil, nil, 10
	releaseRequest()
	msg := awaitCommandSignal(t, done).(commandExecutedMsg)
	if msg.Err != nil || msg.SessionID != "original" || msg.Gen != 9 || !reflect.DeepEqual(msg.Available, []string{"low", "high"}) {
		t.Fatalf("result read changed app state: %+v", msg)
	}
}

func TestGlancePollingCapturesPageNames(t *testing.T) {
	var paths, names []string
	conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
		var body struct{ Name string }
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
		}
		paths, names = append(paths, r.URL.Path), append(names, body.Name)
		_ = json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"page": map[string]any{
			"title": body.Name, "summary": "", "empty": "", "rows": []any{}, "actions": []any{},
			"glance": map[string]any{"title": body.Name, "rows": []any{}},
		}}})
	})
	pageFlag := true
	session := &daemon.Session{ID: "original"}
	app := AppModel{Conn: conn, ActiveSession: session, CommandCatalog: []daemon.SessionCommand{
		{Name: "/first", Page: &pageFlag},
		{Name: "/ordinary"},
		{Name: "/second", Page: &pageFlag},
	}}
	cmd := app.pollGlancesCmd(3)
	pageFlag = false
	app.CommandCatalog[0].Name = "/changed"
	session.ID = "changed"
	app.Conn, app.CommandCatalog, app.GlanceGen = nil, nil, 4
	msg := cmd().(glancesPolledMsg)
	if !reflect.DeepEqual(names, []string{"/first", "/second"}) || !reflect.DeepEqual(paths, []string{"/sessions/original/commands", "/sessions/original/commands"}) {
		t.Fatalf("poll read changed inputs: names=%v paths=%v", names, paths)
	}
	if msg.Gen != 3 || len(msg.Glances) != 2 || msg.Glances[0].Title != "/first" || msg.Glances[1].Title != "/second" {
		t.Fatalf("unexpected glance result: %+v", msg)
	}
}

func TestUIPatchCapturesValues(t *testing.T) {
	for _, sessionID := range []string{"", "original"} {
		t.Run("session="+sessionID, func(t *testing.T) {
			var got map[string]bool
			conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
				wantPath := "/settings/ui"
				if sessionID != "" {
					wantPath += "/sessions/" + sessionID
				}
				if r.URL.Path != wantPath || r.Method != http.MethodPatch {
					t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
				}
				if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
					t.Error(err)
				}
				_, _ = w.Write([]byte(`{"thinking":true,"tools":false,"pinned":[],"archived":[],"opens":{}}`))
			})
			app := AppModel{Conn: conn}
			first, second := true, false
			patch := daemon.UIPreferencesPatch{Thinking: &first, Tools: &second}
			wanted := map[string]bool{"thinking": true, "tools": false}
			if sessionID != "" {
				patch = daemon.UIPreferencesPatch{Pinned: &first, Archived: &second}
				wanted = map[string]bool{"pinned": true, "archived": false}
			}
			cmd := app.patchUICmd(sessionID, patch, 5)
			first, second = false, true
			app.Conn, app.SettingsGen = nil, 6
			msg := cmd().(uiSavedMsg)
			if msg.Err != nil || msg.Gen != 5 || !reflect.DeepEqual(got, wanted) {
				t.Fatalf("patch read changed inputs: body=%v result=%+v", got, msg)
			}
		})
	}
}

func TestPreviewCallbackKeepsConnectionAcrossAppChanges(t *testing.T) {
	conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/sessions/requested/preview" || r.URL.Query().Get("limit") != "16" {
			t.Errorf("unexpected preview target: %s", r.URL)
		}
		_, _ = w.Write([]byte(`{"items":[{"type":"user","preview":"hello"}],"total":1}`))
	})
	app := NewAppModel(conn, config.Profiles{}, nil, "", false, nil)
	app.Conn, app.State = nil, AppStateChat
	app.ActiveSession = &daemon.Session{ID: "different"}
	msg := app.SessionPicker.Fetch("requested")().(SessionPreviewMsg)
	if msg.Err != nil || msg.ID != "requested" || msg.Preview.Total != 1 {
		t.Fatalf("preview callback followed changed app state: %+v", msg)
	}
}
