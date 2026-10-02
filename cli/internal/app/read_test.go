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
)

func TestReadFlattensHistoryPagesInChronologicalOrder(t *testing.T) {
	var cursors []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sessions":
			_, _ = w.Write([]byte(`[{"id":"s"}]`))
		case "/sessions/s/status":
			_, _ = w.Write([]byte(`{"running":true,"idle":false}`))
		case "/sessions/s/history":
			cursor := r.URL.Query().Get("before")
			cursors = append(cursors, cursor)
			var body string
			switch cursor {
			case "":
				body = `{"events":[{"type":"user","source":"chat","triggeredAt":"","text":"third"},{"type":"message","role":"assistant","text":"third reply"}],"before":5,"more":true}`
			case "5":
				body = `{"events":[{"type":"user","source":"chat","triggeredAt":"","text":"second"},{"type":"message","role":"assistant","text":"second reply"}],"before":3,"more":true}`
			case "3":
				body = `{"events":[{"type":"user","source":"chat","triggeredAt":"","text":"first"},{"type":"message","role":"assistant","text":"first reply"}],"before":1,"more":false}`
			default:
				t.Errorf("unexpected cursor %s", cursor)
			}
			_, _ = w.Write([]byte(body))
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
			texts = append(texts, event.Text)
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
