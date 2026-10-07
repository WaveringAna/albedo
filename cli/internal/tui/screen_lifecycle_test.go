// Delayed command delivery and discarded screen instances cannot be scheduled
// deterministically through the terminal E2E harness. These tests exercise real
// API commands and UI updates while controlling only response timing.
package tui

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestReopenedModelPickerRejectsEarlierCatalogAndCancelsItsRead(t *testing.T) {
	started, cancelled := make(chan struct{}), make(chan struct{})
	conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("endpoint") == "https://old.example/v1" {
			close(started)
			<-r.Context().Done()
			close(cancelled)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"items": []any{map[string]any{
			"id": "fresh-model", "label": "Fresh model", "efforts": []any{},
			"default_context_tokens": nil, "effective_context_tokens": nil, "max_context_tokens": nil,
			"max_output_tokens": nil, "input_modalities": []any{}, "image_edge": nil,
			"raised": false, "cap_key": "fresh-model", "cache_policy": map[string]any{"ttl_seconds": nil, "source": nil},
			"source": "provider", "observed_at": nil,
		}}, "next": nil})
	})
	profiles := config.Profiles{Providers: map[string]config.Settings{"work": {Extension: "openai", BaseURL: "https://old.example/v1"}}}
	old := NewModelPickerModel(conn, profiles, "", "work", "")
	t.Cleanup(old.Close)
	delivered := make(chan tea.Msg, 1)
	read := old.listCmd(old.catalogs[0])
	go func() { delivered <- read() }()
	awaitCommandSignal(t, started)
	old.Close()
	awaitCommandSignal(t, cancelled)
	profiles.Providers["work"] = config.Settings{Extension: "openai", BaseURL: "https://new.example/v1"}
	current := NewModelPickerModel(conn, profiles, "", "work", "")
	t.Cleanup(current.Close)
	current, _ = current.Update(awaitCommandSignal(t, delivered))
	if !current.catalogs[0].loading {
		t.Fatal("discarded request settled the replacement picker")
	}
	current, _ = current.Update(current.listCmd(current.catalogs[0])())
	if view := current.View(); !strings.Contains(view, "fresh-model") || current.catalogs[0].failed {
		t.Fatalf("replacement catalog not delivered: %s", view)
	}
}

type heldFolderSource struct {
	*fakeFolders
	entered, cancelled chan struct{}
}

func (source heldFolderSource) List(ctx context.Context, _ string) (daemon.FolderList, error) {
	close(source.entered)
	<-ctx.Done()
	close(source.cancelled)
	return daemon.FolderList{}, ctx.Err()
}

func TestReopenedFolderPickerRejectsEarlierBrowseAndStopsItsRead(t *testing.T) {
	source := heldFolderSource{fakeFolders: &fakeFolders{}, entered: make(chan struct{}), cancelled: make(chan struct{})}
	old := NewFolderPicker(source, daemon.Session{Workspace: "/workspace"}, nil)
	t.Cleanup(old.Close)
	previousGeneration := old.sessionsGeneration
	old.setQuery("/workspace/")
	request := old.fetch()
	delivered := make(chan tea.Msg, 1)
	go func() { delivered <- request() }()
	awaitCommandSignal(t, source.entered)
	old.Close()
	awaitCommandSignal(t, source.cancelled)
	current := NewFolderPicker(&fakeFolders{}, daemon.Session{Workspace: "/workspace"}, nil)
	t.Cleanup(current.Close)
	current.setQuery("/workspace/")
	current, _ = current.Update(awaitCommandSignal(t, delivered))
	current, _ = current.Update(folderListMsg{Gen: previousGeneration, Path: "/workspace", List: daemon.FolderList{Path: "/workspace", Entries: []daemon.FolderEntry{{Name: "obsolete"}}}})
	if strings.Contains(ansi.Strip(current.View()), "obsolete") || current.listings["/workspace"] != nil {
		t.Fatal("discarded browse populated the replacement picker")
	}
	current, _ = current.Update(folderListMsg{Gen: current.sessionsGeneration, Path: "/workspace", List: daemon.FolderList{Path: "/workspace", Entries: []daemon.FolderEntry{{Name: "fresh"}}}})
	if !strings.Contains(ansi.Strip(current.View()), "fresh") {
		t.Fatal("current browse was not delivered")
	}
}

func TestClosedLoginCancelsLateStartupWithoutOpeningBrowser(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	releaseProvider := func() { releaseOnce.Do(func() { close(release) }) }
	t.Cleanup(releaseProvider)
	cancelled := make(chan string, 1)
	created := make(chan string, 1)
	var opened atomic.Bool
	conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.URL.Path, "/auth/logins/")
		if r.Method == http.MethodDelete {
			cancelled <- id
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.Method != http.MethodPut {
			t.Errorf("unexpected %s %s", r.Method, r.URL)
			return
		}
		created <- id
		close(started)
		<-release
		w.Header().Set("ETag", `"observed"`)
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(map[string]any{"id": id, "provider": "provider", "url": "https://login.example/authorize", "expires_at": "2099-01-01T00:00:00Z", "state": "waiting", "instructions": nil, "progress": "waiting", "accounts": []any{}, "failure": nil})
	})
	app := NewAppModel(conn, Bootstrap{Settings: daemon.Settings{Profiles: config.Profiles{}}}, nil, "", false, func(string) { opened.Store(true) })
	app.State = AppStateLogin
	app.Login = NewLoginModel(conn, "", app.openBrowser)
	app.Login.Provider = "provider"
	delivered := make(chan tea.Msg, 1)
	command := app.Login.beginLoginCmd()
	go func() { delivered <- command() }()
	awaitCommandSignal(t, started)
	expectedID := awaitCommandSignal(t, created)
	app.Login.Close()
	app.State = AppStateSessionPicker
	releaseProvider()
	result := awaitCommandSignal(t, delivered).(signInStartedMsg)
	updated, cleanup := app.Update(result)
	app = updated.(*AppModel)
	if cleanup != nil {
		t.Fatal("completed cleanup was scheduled a second time")
	}
	if id := awaitCommandSignal(t, cancelled); id != expectedID {
		t.Fatalf("cancelled a different login: %s", id)
	}
	if opened.Load() || app.State != AppStateSessionPicker {
		t.Fatal("late login opened a browser or took over the screen")
	}
}

func TestLateProviderMutationKeepsUncertaintyWithoutSelectingReplacementFlow(t *testing.T) {
	conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, nil)
	app := NewAppModel(conn, Bootstrap{Settings: daemon.Settings{Profiles: config.Profiles{}}}, nil, "", false, nil)
	previous := NewLoginModel(conn, "", nil)
	conn.HTTPClient().Transport = catalogTransport(func(*http.Request) (*http.Response, error) { return nil, io.ErrUnexpectedEOF })
	// Capture the observed validator before creating the mutation command.
	previous.Profiles.ETag = `"seen"`
	command := previous.saveProviderCmd("work", config.Settings{Extension: "openai", Protocol: "responses", BaseURL: "https://provider.example/v1", Model: "model"})
	previous.Close()
	app.Login = NewLoginModel(conn, "", nil)
	t.Cleanup(func() { app.Login.Close() })
	app.State = AppStateLogin
	result := command().(providerSavedMsg)
	if _, ok := errors.AsType[*daemon.UncertainOutcomeError](result.Err); !ok {
		t.Fatalf("missing uncertainty: %v", result.Err)
	}
	updated, followup := app.Update(result)
	app = updated.(*AppModel)
	if followup != nil || app.Login.Name != "" || app.State != AppStateLogin || len(app.Notices) == 0 {
		t.Fatal("late mutation was hidden or selected the replacement login flow")
	}
	if !strings.Contains(ansi.Strip(app.content()), "may have been accepted") {
		t.Fatal("uncertain outcome was not visible in the replacement login screen")
	}
}
