package tui

import (
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/testwire"
	"encoding/json"
	"net/http"
	"slices"
	"testing"

	tea "charm.land/bubbletea/v2"
)

// settleApp runs cmd and feeds every message it produces back into app, as the
// program would, leaving out the preview timers.
func settleApp(app *AppModel, cmd tea.Cmd) {
	queue := []tea.Cmd{cmd}
	for len(queue) > 0 {
		next := queue[0]
		queue = queue[1:]
		if next == nil {
			continue
		}
		switch msg := next().(type) {
		case tea.BatchMsg:
			queue = append(queue, msg...)
		case nil, sessionPreviewTickMsg, sessionsLoadedMsg:
		default:
			updated, more := app.Update(msg)
			*app = *updated.(*AppModel)
			queue = append(queue, more)
		}
	}
}

// A session list requested before an archive answers after it; the picker
// must not bring the archived row back from that older listing.
func TestArchiveOutlivesAnOlderSessionListing(t *testing.T) {
	conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
		session := testwire.Session("s1", testwire.GenerationA, 0)
		resource := session["configuration_resource"].(map[string]any)
		switch r.Method {
		case "GET":
			w.Header().Set("ETag", resource["etag"].(string))
			_ = json.NewEncoder(w).Encode(resource["value"])
		case "PATCH":
			session["preferences"].(map[string]any)["archived"] = true
			resource["value"].(map[string]any)["preferences"].(map[string]any)["archived"] = true
			_ = json.NewEncoder(w).Encode(map[string]any{"resource": resource, "session": session, "move": nil})
		}
	})
	app := NewAppModel(conn, Bootstrap{}, nil, "", false, nil)
	app.State = AppStateSessionPicker
	listed := []daemon.Session{{ID: "s1", Title: "one", Workspace: "/work"}}
	updated, _ := app.Update(sessionsLoadedMsg{Gen: app.SessionGen, Sessions: listed})
	app = updated.(*AppModel)
	// Reopening the list asks for a listing that answers after the archive.
	app.openSessions()
	older := sessionsLoadedMsg{Gen: app.SessionGen, Sessions: slices.Clone(listed)}

	updated, cmd := app.Update(tea.KeyPressMsg{Code: 'a', Mod: tea.ModCtrl})
	app = updated.(*AppModel)
	settleApp(app, cmd)
	if !app.SessionPicker.archivedIDs["s1"] {
		t.Fatalf("ctrl+a did not archive the row: %q", app.SessionPicker.notice)
	}
	updated, cmd = app.Update(older)
	app = updated.(*AppModel)
	settleApp(app, cmd)
	if !app.SessionPicker.archivedIDs["s1"] {
		t.Fatal("an older listing brought the archived session back")
	}
}
