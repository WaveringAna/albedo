package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestStreamAsksForATailAndReadsItsCursor(t *testing.T) {
	var query string
	page := formatPage(3, []any{
		map[string]any{"type": "reset", "before": 40, "more": true},
		map[string]any{"type": "user", "text": "hi", "source": "chat"},
		map[string]any{"type": "committed", "seq": 41},
	})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		query = r.URL.RawQuery
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte(page))
	}))
	defer server.Close()

	client := NewChatClient(ChatClientOptions{BaseURL: server.URL, AgentID: "s"})
	client.Tail = 120
	var events []StreamEvent
	if err := client.Stream(context.Background(), nil, func(e StreamEvent) error {
		events = append(events, e)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if query != "after_seq=0&tail=120" && query != "after_seq=-1&tail=120" {
		t.Fatalf("stream query %q does not ask for a tail", query)
	}
	if len(events) != 3 || events[0].Type != EventReset || events[0].Before != 40 || !events[0].More {
		t.Fatalf("reset cursor not read: %+v", events)
	}
	if events[2].Type != EventCommitted || events[2].Seq != 41 || !events[2].Replayed {
		t.Fatalf("committed marker not read: %+v", events[2])
	}
}

func TestHistoryReadsAnOlderPage(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/sessions/s/history" || r.URL.Query().Get("before") != "40" || r.URL.Query().Get("rows") != "120" {
			t.Errorf("unexpected request %s", r.URL)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"events": []any{
				map[string]any{"type": "user", "text": "older", "source": "chat"},
				map[string]any{"type": "tool", "callId": "c", "name": "python", "args": `{"code":"1"}`, "result": "1"},
				map[string]any{"type": "committed", "seq": 39},
			},
			"before": 12,
			"more":   true,
		})
	}))
	defer server.Close()

	client := NewChatClient(ChatClientOptions{BaseURL: server.URL, AgentID: "s"})
	page, err := client.History(context.Background(), 40, 120)
	if err != nil {
		t.Fatal(err)
	}
	if page.Before != 12 || !page.More || len(page.Events) != 3 {
		t.Fatalf("unexpected page: %+v", page)
	}
	if page.Events[1].ToolArgs["code"] != "1" || !page.Events[0].Replayed {
		t.Fatalf("events not normalized: %+v", page.Events)
	}
}
