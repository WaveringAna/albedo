// Controlled page boundaries catch ordering and turn selection bugs without
// requiring hundreds of provider turns to cross the daemon's page limit.
package app

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/testwire"
)

func TestReadFlattensHistoryPagesInChronologicalOrder(t *testing.T) {
	var cursors []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sessions":
			_ = json.NewEncoder(w).Encode(map[string]any{"items": []any{testwire.Session("s", testwire.GenerationA, 0)}, "next": nil})
		case "/sessions/s":
			session := testwire.Session("s", testwire.GenerationA, 0)
			session["status"].(map[string]any)["phase"] = "preparing"
			_ = json.NewEncoder(w).Encode(session)
		case "/sessions/s/history":
			cursor := r.URL.Query().Get("before")
			cursors = append(cursors, cursor)
			position := int64(5)
			text := "third"
			var older any = "older"
			switch cursor {
			case "5":
				position, text = 3, "second"
			case "3":
				position, text, older = 1, "first", nil
			}
			makeEntry := func(id, kind, text string, position int64) map[string]any {
				return map[string]any{"id": id, "position": position, "kind": kind, "created_at": nil, "input_id": nil, "turn_id": nil, "checkpoint_id": nil, "content_complete": true, "content": []any{map[string]any{"kind": "text", "text": text}}, "tool": nil}
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"items": []any{makeEntry(text, "user", text, position), makeEntry(text+"-reply", "assistant", text+" reply", position+1)}, "older": older, "newer": nil, "high_water": 6})
		default:
			t.Errorf("unexpected request %s", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer server.Close()
	conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
	service := Service{Connect: func(context.Context) (*daemon.Connection, error) { return conn, nil }}
	for _, turns := range []int{3, 2} {
		cursors = nil
		result, err := service.Read(context.Background(), "s", turns)
		if err != nil {
			t.Fatal(err)
		}
		var texts []string
		for _, event := range result.Events {
			if event.Type != daemon.EventCommitted {
				texts = append(texts, event.Text)
			}
			if !event.Replayed {
				t.Fatal("history event not marked replayed")
			}
		}
		wanted := []string{"first", "first reply", "second", "second reply", "third", "third reply"}
		if turns == 2 {
			wanted = wanted[2:]
		}
		if !reflect.DeepEqual(texts, wanted) || !result.Running {
			data, _ := json.Marshal(result)
			t.Fatalf("history changed order or running state: %s", data)
		}
		expectedCursors := []string{"", "5", "3"}
		if turns == 2 {
			expectedCursors = expectedCursors[:2]
		}
		if !reflect.DeepEqual(cursors, expectedCursors) {
			t.Fatalf("read fetched wrong pages: %v", cursors)
		}
	}
}
