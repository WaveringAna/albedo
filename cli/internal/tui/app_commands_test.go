// Delayed controlled responses verify that commands retain captured UI inputs.
package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/testwire"
	tea "charm.land/bubbletea/v2"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sync"
	"testing"
	"time"
)

func commandTestConnection(t *testing.T, handler http.HandlerFunc) *daemon.Connection {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/server" {
			_, _ = w.Write([]byte(testwire.Server))
			return
		}
		handler(w, r)
	}))
	t.Cleanup(server.Close)
	conn, err := daemon.Attach(t.Context(), daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "token"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(conn.HTTPClient().CloseIdleConnections)
	return conn
}
func awaitCommandSignal[T any](t *testing.T, ch <-chan T) T {
	t.Helper()
	select {
	case value := <-ch:
		return value
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for command")
		var zero T
		return zero
	}
}

// A partial deletion must keep an undeleted row until an authoritative refresh.
// A healthy daemon cannot reliably force a teardown failure during this update.
func TestPartialDeletionKeepsUndeletedSessionAndOutcomeAfterRefresh(t *testing.T) {
	app := NewAppModel(daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, nil), config.Profiles{}, nil, "", false, nil)
	app.State = AppStateSessionPicker
	app.Sessions = []daemon.Session{{ID: "root"}, {ID: "deleted"}}
	app.updateSessionPickerItems()
	result := daemon.DeletionResult{State: "partial", Deleted: 1, Remaining: 1, DeletedIDs: []string{"deleted"}, Message: "Deleted 1 sessions; 1 remain. root: kernel teardown failed"}
	updated, command := app.Update(sessionDeletedMsg{ID: "root", Result: &result})
	app = updated.(*AppModel)
	if command == nil || len(app.Sessions) != 1 || app.Sessions[0].ID != "root" || app.SessionPicker.notice != result.Message {
		t.Fatalf("partial deletion invented completion: command nil=%v rows=%d id=%q notice=%q wanted=%q", command == nil, len(app.Sessions), app.Sessions[0].ID, app.SessionPicker.notice, result.Message)
	}
	updated, _ = app.Update(sessionsLoadedMsg{Gen: app.SessionGen, Sessions: app.Sessions, Notice: result.Message})
	app = updated.(*AppModel)
	if app.SessionPicker.notice != result.Message {
		t.Fatal("refresh erased the partial operation outcome")
	}
}
func TestModelChangeCapturesProviderAndCapBeforeExecution(t *testing.T) {
	for _, failure := range []string{"", "switch", "default", "cap"} {
		t.Run(failure, func(t *testing.T) {
			var paths []string
			var switchBody map[string]string
			var capBody map[string]map[string]bool
			conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
				paths = append(paths, r.URL.String())
				if r.URL.Path == "/sessions/original" {
					if r.Header.Get("If-Match") != "\"session-a\"" {
						t.Errorf("changed session validator %s", r.Header.Get("If-Match"))
					}
					_ = json.NewDecoder(r.Body).Decode(&switchBody)
					if failure == "switch" {
						w.WriteHeader(400)
						return
					}
					writeSessionChange(w, "original", "resolved", "new")
					return
				}
				group := r.URL.Query().Get("group")
				if r.URL.Path != "/settings" {
					t.Errorf("unexpected route %s", r.URL)
				}
				if failure == group || failure == "default" && group == "providers" || failure == "cap" && group == "models" {
					w.WriteHeader(400)
					return
				}
				settings := testwire.Settings()
				if group == "models" {
					_ = json.NewDecoder(r.Body).Decode(&capBody)
				}
				_ = json.NewEncoder(w).Encode(testwire.SettingsChange(group, settings[group]))
			})
			session := &daemon.Session{ID: "original", Provider: "old", ETag: "\"session-a\""}
			app := &AppModel{Conn: conn, ActiveSession: session, Profiles: config.Profiles{ETag: "\"providers-a\"", Providers: map[string]config.Settings{"new": {Protocol: "responses"}}}, SettingsETags: map[string]string{"models": "\"models-a\""}}
			raised := true
			cmd := app.changeModelCmd("chosen", "new", "high", &raised, 7, "provider/cap")
			session.ID, session.Provider = "changed", "new"
			raised = false
			app.Conn, app.ActiveSession = nil, nil
			msg := cmd().(modelChangedMsg)
			if msg.SessionID != "original" || msg.Gen != 7 || (msg.Err != nil) != (failure != "") {
				t.Fatalf("captured result changed: %+v", msg)
			}
			if !reflect.DeepEqual(switchBody, map[string]string{"model": "chosen", "provider_profile": "new", "effort": "high"}) {
				t.Fatalf("switch inputs changed: %v", switchBody)
			}
			expected := 1
			if failure != "switch" {
				expected = 2
				if failure != "default" {
					expected = 3
				}
			}
			if len(paths) != expected {
				t.Fatalf("wrong partial workflow %v", paths)
			}
			if failure == "switch" {
				if msg.Selection != nil {
					t.Fatal("failed switch installed")
				}
			} else if msg.Selection == nil || msg.Selection.Model != "resolved" {
				t.Fatal("confirmed switch lost")
			}
			if failure == "" && !capBody["raised_caps"]["provider/cap"] {
				t.Fatalf("cap input changed %v", capBody)
			}
		})
	}
}
func TestSessionCommandKeepsSessionWhileRequestIsRunning(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	releaseRequest := func() { once.Do(func() { close(release) }) }
	conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/models" || r.URL.Query().Get("model") != "current" {
			t.Errorf("wrong effort metadata %s", r.URL)
		}
		close(started)
		<-release
		_ = json.NewEncoder(w).Encode(map[string]any{"items": []any{testwire.Model("current")}, "next": nil})
	})
	t.Cleanup(releaseRequest)
	session := &daemon.Session{ID: "original", Model: "current"}
	app := &AppModel{Conn: conn, ActiveSession: session}
	cmd := app.executeCommandCmd("/effort", "", 9)
	done := make(chan tea.Msg, 1)
	go func() { done <- cmd() }()
	awaitCommandSignal(t, started)
	session.ID = "changed"
	app.Conn, app.ActiveSession = nil, nil
	releaseRequest()
	msg := awaitCommandSignal(t, done).(commandExecutedMsg)
	if msg.Err != nil || msg.SessionID != "original" || msg.Gen != 9 || !reflect.DeepEqual(msg.Available, []string{"low", "high"}) {
		t.Fatalf("result used changed app state %+v", msg)
	}
}
func TestStatusAndGlancesUseOneCapturedSessionSnapshot(t *testing.T) {
	var paths []string
	conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		if r.URL.RawQuery != "tail=0" {
			t.Errorf("state polling repeated history reads: %s", r.URL)
		}
		session := protocolSession("original", generationA, 0)
		session["kernel"] = map[string]any{"state": "attached", "build": "observed-build", "stale": true, "staleness_reasons": []any{map[string]any{"code": "build_changed", "detail": "A newer kernel is available."}}, "live_job_count": 3, "running_jobs": []any{map[string]any{"id": "job1", "pid": 123, "command": "sleep 10", "started_at": 0}}, "stage": nil, "instance_id": "observed-kernel"}
		session["glances"] = []any{map[string]any{"extension": "first", "title": "First", "rows": []any{}, "url": "/extensions/first/items"}, map[string]any{"extension": "second", "title": "Second", "rows": []any{}, "url": "/extensions/second/items"}}
		_ = json.NewEncoder(w).Encode(session)
	})
	session := &daemon.Session{ID: "original"}
	chat := NewChatModel(session, daemon.NewChatClient(conn, session.ID))
	t.Cleanup(chat.Close)
	cmd := chat.statusCmd()
	session.ID = "changed"
	chat.SessionID = "changed"
	msg := cmd().(ChatStatusMsg)
	if !reflect.DeepEqual(paths, []string{"/sessions/original"}) || msg.Err != nil || msg.SessionID != "original" || msg.Status == nil || len(msg.Glances) != 2 {
		t.Fatalf("glance capture changed %+v %v", msg, paths)
	}
	chat.SessionID = "original"
	chat.Glances = []PageGlance{{Title: "confirmed"}}
	app := &AppModel{ActiveSession: &daemon.Session{ID: "original"}, Chat: chat}
	updated, refresh := app.Update(PageViewChangedMsg{})
	app = updated.(*AppModel)
	updated, _ = app.Update(msg)
	app = updated.(*AppModel)
	if refresh == nil || len(app.Chat.Glances) != 1 || app.Chat.Glances[0].Title != "confirmed" {
		t.Fatal("an earlier state read overwrote the acknowledged page change")
	}
	updated, _ = app.Update(refresh().(ChatStatusMsg))
	app = updated.(*AppModel)
	if len(app.Chat.Glances) != 2 {
		t.Fatal("the state read after the page change was discarded")
	}
	phase := daemon.PhaseModel
	app.Chat.handleStreamEvent(daemon.StreamEvent{Type: "status", Status: &daemon.AgentStatus{Phase: &phase, Running: true}})
	status := app.Chat.Status
	if status.Phase == nil || *status.Phase != phase || !status.Running || status.KernelLink != "attached" || !status.KernelStale || status.KernelJobs == nil || *status.KernelJobs != 3 || len(status.RunningJobs) != 1 || status.RunningJobs[0].Command != "sleep 10" || status.KernelBuild == nil || *status.KernelBuild != "observed-build" || status.KernelInstanceID == nil || *status.KernelInstanceID != "observed-kernel" {
		t.Fatalf("lightweight live status lost the last captured kernel observation: %+v", status)
	}
}
func TestUIPatchCapturesValuesAndObservedValidator(t *testing.T) {
	for _, sessionID := range []string{"", "original"} {
		t.Run(sessionID, func(t *testing.T) {
			var got map[string]any
			conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
				if r.Method != "PATCH" || r.Header.Get("If-Match") != "\"seen\"" {
					t.Errorf("conditional edit changed %s %v", r.Method, r.Header)
				}
				_ = json.NewDecoder(r.Body).Decode(&got)
				if sessionID == "" {
					if r.URL.String() != "/settings?group=ui" {
						t.Errorf("wrong route %s", r.URL)
					}
					_ = json.NewEncoder(w).Encode(testwire.SettingsChange("ui", testwire.Settings()["ui"]))
				} else {
					if r.URL.String() != "/sessions/original?view=configuration" {
						t.Errorf("wrong route %s", r.URL)
					}
					writeSessionChange(w, "original", "current", "provider")
				}
			})
			app := &AppModel{Conn: conn}
			app.SessionPicker.prefs.ETag = "\"seen\""
			first, second := true, false
			patch := daemon.UIPreferencesPatch{Thinking: &first, Tools: &second}
			if sessionID != "" {
				patch = daemon.UIPreferencesPatch{Pinned: &first, Archived: &second, ETag: "\"seen\""}
			}
			cmd := app.patchUICmd(sessionID, patch, 5)
			first, second = false, true
			app.Conn = nil
			msg := cmd().(uiSavedMsg)
			if msg.Err != nil || msg.Gen != 5 {
				t.Fatalf("patch failed %+v", msg)
			}
			if sessionID != "" {
				got = got["preferences"].(map[string]any)
			}
			firstKey, secondKey := "thinking", "tools"
			if sessionID != "" {
				firstKey, secondKey = "pinned", "archived"
			}
			if got[firstKey] != true || got[secondKey] != false {
				t.Fatalf("captured values changed %v", got)
			}
		})
	}
}
func TestPreviewCallbackKeepsConnectionAcrossAppChanges(t *testing.T) {
	conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.String() != "/sessions/requested/history?limit=16" {
			t.Errorf("unexpected preview %s", r.URL)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"high_water": 1, "items": []any{protocolEntry("e", "user", "hello", 1)}, "older": nil, "newer": nil})
	})
	app := NewAppModel(conn, config.Profiles{}, nil, "", false, nil)
	app.Conn = nil
	msg := app.SessionPicker.Fetch("requested")().(SessionPreviewMsg)
	if msg.Err != nil || msg.ID != "requested" || len(msg.Preview.Items) != 1 || msg.Preview.Items[0].Preview != "hello" {
		t.Fatalf("preview followed changed app state %+v", msg)
	}
}
