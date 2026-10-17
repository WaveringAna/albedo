// A configuration validator lives only in this client's memory, so a daemon
// E2E sees the request and the refusal but never which validator the app kept
// or when it replaced it. These cover how it goes stale: a live invalidation, a
// session opened from a listing that carries neither validator, and a change
// the daemon refused, for the session's configuration or for the provider
// default a model change saves with it.
package tui

import (
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/testwire"
	tea "charm.land/bubbletea/v2"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"
)

// sessionWire is the session representation a fact read returns.
func sessionWire(etag, model, familyRevision string) map[string]any {
	session := testwire.Session("s", generationA, 0)
	session["model"] = model
	session["family_revision"] = familyRevision
	session["configuration_resource"].(map[string]any)["etag"] = etag
	return session
}

// sessionServer answers a session read with the facts it reports, and every
// patch with the session change the fixtures carry.
func sessionServer(etag, model, familyRevision string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			_ = json.NewEncoder(w).Encode(sessionWire(etag, model, familyRevision))
			return
		}
		_, _ = io.Copy(io.Discard, r.Body)
		writeSessionChange(w, "s", model, "old")
	}
}

// awaitCommand runs the commands until one answers with a message match
// accepts. The commands it leaves behind wait on the chat's stream, which
// returns when Chat.Close closes it.
func awaitCommand(t *testing.T, command tea.Cmd, match func(tea.Msg) bool) tea.Msg {
	t.Helper()
	found := make(chan tea.Msg, 1)
	var walk func(tea.Cmd)
	walk = func(command tea.Cmd) {
		if command == nil {
			return
		}
		go func() {
			switch msg := command().(type) {
			case tea.BatchMsg:
				for _, nested := range msg {
					walk(nested)
				}
			default:
				if match(msg) {
					found <- msg
				}
			}
		}()
	}
	walk(command)
	select {
	case msg := <-found:
		return msg
	case <-time.After(5 * time.Second):
		t.Fatal("no expected answer among the commands")
		return nil
	}
}

func awaitSessionFacts(t *testing.T, command tea.Cmd) sessionFactsMsg {
	t.Helper()
	msg, ok := awaitCommand(t, command, func(msg tea.Msg) bool {
		_, facts := msg.(sessionFactsMsg)
		return facts
	}).(sessionFactsMsg)
	if !ok {
		t.Fatal("no session read among the commands")
	}
	return msg
}

func TestSessionInvalidationRefreshesTheConfiguration(t *testing.T) {
	conn := commandTestConnection(t, sessionServer(`"seen-b"`, "second", "family-b"))
	app := NewAppModel(conn, Bootstrap{}, &daemon.Session{ID: "s", Model: "first", Provider: "old", ETag: `"seen-a"`, FamilyRevision: "family-a"}, "", false, nil)
	t.Cleanup(app.Chat.Close)
	_, command := app.Update(ChatStreamEventMsg{
		SessionID:  "s",
		Generation: app.Chat.Generation,
		Event:      daemon.StreamEvent{Type: daemon.EventInvalidate, Invalidation: &daemon.ResourceInvalidation{Session: true, Settings: true}},
	})
	msg := awaitSessionFacts(t, command)
	_, _ = app.Update(msg)
	if app.ActiveSession.ETag != `"seen-b"` || app.ActiveSession.Model != "second" || app.Chat.Model != "second" || app.ActiveSession.FamilyRevision != "family-b" {
		t.Fatalf("invalidation left stale facts: etag=%q model=%q chat=%q family=%q", app.ActiveSession.ETag, app.ActiveSession.Model, app.Chat.Model, app.ActiveSession.FamilyRevision)
	}
}

func TestRefusedModelChangeReadsTheValidatorBeforeTheNextAttempt(t *testing.T) {
	seen := make(chan string, 4)
	conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/settings" {
			_, _ = io.Copy(io.Discard, r.Body)
			if r.Method == http.MethodGet {
				t.Errorf("a refused session change read the settings")
				return
			}
			group := r.URL.Query().Get("group")
			settings := testwire.Settings()
			_ = json.NewEncoder(w).Encode(testwire.SettingsChange(group, settings[group]))
			return
		}
		if r.Method == http.MethodGet {
			_ = json.NewEncoder(w).Encode(sessionWire(`"seen-b"`, "second", "family-b"))
			return
		}
		_, _ = io.Copy(io.Discard, r.Body)
		observed := r.Header.Get("If-Match")
		seen <- observed
		if observed != `"seen-b"` {
			w.Header().Set("Content-Type", "application/problem+json")
			w.WriteHeader(http.StatusPreconditionFailed)
			_, _ = io.WriteString(w, `{"type":"about:blank","title":"precondition_failed","status":412,"detail":"the observed resource has changed","code":"precondition_failed"}`)
			return
		}
		writeSessionChange(w, "s", "second", "old")
	})
	app := NewAppModel(conn, Bootstrap{}, &daemon.Session{ID: "s", Model: "first", Provider: "old", ETag: `"seen-a"`}, "", false, nil)
	app.Profiles.ETag = `"providers-a"`
	t.Cleanup(app.Chat.Close)

	refused := app.changeModelCmd("second", "old", "", nil, app.ModelGen, "")()
	_, command := app.Update(refused)
	if app.ActiveSession.ETag != `"seen-a"` {
		t.Fatalf("a refused change moved the validator to %q", app.ActiveSession.ETag)
	}
	msg := awaitSessionFacts(t, command)
	_, _ = app.Update(msg)
	if app.ActiveSession.ETag != `"seen-b"` {
		t.Fatalf("refusal left validator %q, want the refreshed one", app.ActiveSession.ETag)
	}

	accepted := app.changeModelCmd("second", "old", "", nil, app.ModelGen, "")()
	if message, ok := accepted.(modelChangedMsg); !ok || message.Err != nil {
		t.Fatalf("retried change failed: %+v", accepted)
	}
	if observed := <-seen; observed != `"seen-a"` {
		t.Fatalf("first attempt used %q", observed)
	}
	if observed := <-seen; observed != `"seen-b"` {
		t.Fatalf("retry used %q, want the refreshed validator", observed)
	}
}

func TestOpeningAListedSessionReadsItsFacts(t *testing.T) {
	conn := commandTestConnection(t, sessionServer(`"seen-b"`, "second", "family-b"))
	app := NewAppModel(conn, Bootstrap{}, nil, "", false, nil)
	t.Cleanup(app.Chat.Close)
	// The read comes last: the chat's own commands wait on a stream this test
	// does not serve.
	batch := app.setChatSession(daemon.Session{ID: "s", Title: "s"}, false)().(tea.BatchMsg)
	msg, ok := batch[len(batch)-1]().(sessionFactsMsg)
	if !ok {
		t.Fatalf("opening a session ran %T, want its session read", msg)
	}
	_, _ = app.Update(msg)
	if app.ActiveSession.ETag != `"seen-b"` || app.ActiveSession.Model != "second" || app.Chat.Model != "second" || app.ActiveSession.FamilyRevision != "family-b" {
		t.Fatalf("opened session kept etag=%q model=%q family=%q", app.ActiveSession.ETag, app.ActiveSession.Model, app.ActiveSession.FamilyRevision)
	}
}

func TestRefusedProviderDefaultReadsTheGroupBeforeTheNextAttempt(t *testing.T) {
	seen := make(chan string, 4)
	conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/settings" {
			_, _ = io.Copy(io.Discard, r.Body)
			if r.Method == http.MethodGet {
				_ = json.NewEncoder(w).Encode(testwire.Settings())
				return
			}
			observed := r.Header.Get("If-Match")
			seen <- observed
			if observed != `"providers-a"` {
				w.Header().Set("Content-Type", "application/problem+json")
				w.WriteHeader(http.StatusPreconditionFailed)
				_, _ = io.WriteString(w, `{"type":"about:blank","title":"precondition_failed","status":412,"detail":"provider settings changed during the edit","code":"settings_changed"}`)
				return
			}
			group := r.URL.Query().Get("group")
			settings := testwire.Settings()
			_ = json.NewEncoder(w).Encode(testwire.SettingsChange(group, settings[group]))
			return
		}
		_, _ = io.Copy(io.Discard, r.Body)
		writeSessionChange(w, "s", "second", "old")
	})
	app := NewAppModel(conn, Bootstrap{}, &daemon.Session{ID: "s", Model: "first", Provider: "old", ETag: `"seen-a"`}, "", false, nil)
	app.Profiles.ETag = `"providers-b"`
	t.Cleanup(app.Chat.Close)

	refused := app.changeModelCmd("second", "old", "", nil, app.ModelGen, "")()
	changed, ok := refused.(modelChangedMsg)
	if !ok || changed.Err == nil || changed.Selection == nil {
		t.Fatalf("refused default save: %+v", refused)
	}
	_, command := app.Update(changed)
	settings, ok := awaitCommand(t, command, func(msg tea.Msg) bool {
		_, loaded := msg.(settingsLoadedMsg)
		return loaded
	}).(settingsLoadedMsg)
	if !ok {
		t.Fatal("a refused provider default did not read the group")
	}
	_, _ = app.Update(settings)
	if app.Profiles.ETag != `"providers-a"` {
		t.Fatalf("providers group kept %q after its read", app.Profiles.ETag)
	}
	accepted := app.changeModelCmd("second", "old", "", nil, app.ModelGen, "")()
	if message, ok := accepted.(modelChangedMsg); !ok || message.Err != nil {
		t.Fatalf("retried change failed: %+v", accepted)
	}
	if observed := <-seen; observed != `"providers-b"` {
		t.Fatalf("first attempt used %q", observed)
	}
	if observed := <-seen; observed != `"providers-a"` {
		t.Fatalf("retry used %q, want the refreshed group", observed)
	}
}
