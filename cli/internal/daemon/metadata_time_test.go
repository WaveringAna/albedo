// The HTTP adapter must preserve date units across metadata and stream consumers.
// A controlled peer supplies subsecond dates that ordinary daemon timestamps
// cannot deterministically place relative to the presentation clock.
package daemon

import (
	"albedo/cli/internal/presentation"
	"encoding/json"
	"net/http"
	"testing"
	"time"
)

func TestMetadataDatesProduceCorrectAges(t *testing.T) {
	activity := time.Date(2026, 9, 20, 12, 30, 0, 123456789, time.UTC)
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sessions/s":
			session := canonicalSession("s", generationA, 0)
			session["activity_at"] = activity.Format(time.RFC3339Nano)
			if r.Header.Get("Accept") == "text/event-stream" {
				session["usage"].(map[string]any)["observed_at"] = activity.Format(time.RFC3339Nano)
				w.Header().Set("Content-Type", "text/event-stream")
				writeBatch(w, map[string]any{"generation": generationA, "cursor": 0, "snapshot": session, "events": []any{map[string]any{"type": "reset", "data": map[string]any{"reason": "initial"}}}})
				return
			}
			_ = json.NewEncoder(w).Encode(session)
		case "/workspaces":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"directory": "/work", "parent": "/", "home": "/home", "host": nil, "next": nil,
				"items": []any{map[string]any{"name": "project", "location": "/work/project", "vcs": "git", "modified_at": activity.Format(time.RFC3339Nano), "hidden": false}},
				"preview": map[string]any{
					"repository":            map[string]any{"kind": "git", "root": "/work", "branch": "main", "revision": "revision", "dirty": false, "added": 0, "modified": 0, "removed": 0, "changed": 0, "touched_at": activity.Format(time.RFC3339Nano)},
					"repository_diagnostic": nil, "languages": []any{}, "tree": []any{}, "more": 0,
				},
			})
		default:
			t.Errorf("unexpected request: %s", r.URL)
		}
	})
	session, err := GetSession(t.Context(), conn, "s")
	if err != nil {
		t.Fatal(err)
	}
	folders, err := ListFolders(t.Context(), conn, "/work")
	if err != nil {
		t.Fatal(err)
	}
	repo, err := FolderRepo(t.Context(), conn, "/work")
	if err != nil || repo == nil {
		t.Fatalf("repository: %v, %v", repo, err)
	}
	if len(folders.Entries) != 1 {
		t.Fatalf("folders: %v", folders.Entries)
	}
	now := activity.Add(72 * time.Hour)
	for name, timestamp := range map[string]*int64{"session": session.LastAssistantAt, "folder": &folders.Entries[0].Modified, "repository": repo.Touched} {
		if age := presentation.AssistantAge(timestamp, now); age != "3d ago" {
			t.Errorf("%s date produced %q", name, age)
		}
	}
	var recordedAt *int64
	if err := NewChatClient(conn, "s").Stream(t.Context(), 0, func(event StreamEvent) error {
		if event.Type == EventUsage {
			recordedAt = event.Usage.RecordedAt
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if recordedAt == nil || *recordedAt != activity.UnixMilli() {
		t.Fatalf("usage lost its millisecond timestamp: %v", recordedAt)
	}
}
