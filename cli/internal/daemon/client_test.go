// Stream preview state across partial tool arguments, detach, and snapshot boundaries is race-prone and hard to force with a live daemon.
package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func formatPage(cursor int, events []any) string {
	b, _ := json.Marshal(map[string]any{
		"cursor": cursor,
		"events": events,
	})
	return fmt.Sprintf("data: %s\n\n", string(b))
}

func TestCompletedCallPreviewsReleaseState(t *testing.T) {
	aData, _ := json.Marshal(map[string]any{"code": "read('first.py')"})
	bData, _ := json.Marshal(map[string]any{"code": "read('second.py')"})
	a := string(aData)
	b := string(bData)

	var reqCount int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count := atomic.AddInt32(&reqCount, 1)
		w.Header().Set("Content-Type", "text/event-stream")
		if count == 1 {
			_, _ = w.Write([]byte(formatPage(1, []any{
				map[string]any{"type": "arguments_delta", "name": "python", "callId": "a", "text": a},
				map[string]any{"type": "arguments_delta", "name": "python", "callId": "b", "text": b[:15]},
				map[string]any{"type": "tool", "callId": "a", "name": "python", "args": a, "result": "done"},
			})))
		} else {
			_, _ = w.Write([]byte(formatPage(2, []any{
				map[string]any{"type": "arguments_delta", "name": "python", "callId": "b", "text": b[15:]},
				map[string]any{"type": "tool_progress", "progress": map[string]any{"callId": "b", "name": "python", "phase": "running"}},
				map[string]any{"type": "tool", "callId": "b", "name": "python", "args": b, "result": "done"},
			})))
		}
	}))
	defer server.Close()

	client := NewChatClient(ChatClientOptions{
		BaseURL: server.URL,
		AgentID: "session",
	})

	var events []StreamEvent
	_ = client.Stream(context.Background(), nil, func(event StreamEvent) error {
		events = append(events, event)
		return nil
	})
	_ = client.Stream(context.Background(), nil, func(event StreamEvent) error {
		events = append(events, event)
		return nil
	})

	hasSecondPreview := false
	for _, ev := range events {
		if ev.Type == EventToolProgress && ev.Progress != nil && ev.Progress.Code != nil {
			if ev.Progress.Code.Text == "read('second.py')" {
				hasSecondPreview = true
				break
			}
		}
	}
	if !hasSecondPreview {
		t.Fatal("expected second.py progress preview")
	}

	runningIdx := -1
	for i, ev := range events {
		if ev.Type == EventToolProgress && ev.Progress != nil && ev.Progress.Phase == "running" {
			runningIdx = i
			break
		}
	}
	if runningIdx <= 0 {
		t.Fatal("expected running progress event preceded by clear")
	}
	if events[runningIdx-1].Type != EventToolProgress || events[runningIdx-1].Progress != nil {
		t.Fatalf("expected nil progress before running, got: %+v", events[runningIdx-1])
	}

	if events[len(events)-1].Type != EventTool {
		t.Fatalf("expected last event tool, got: %+v", events[len(events)-1])
	}
}

func TestUnfinishedArgumentsBounded(t *testing.T) {
	var requestedURLs []string
	var serverCallCount int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestedURLs = append(requestedURLs, r.URL.String())
		count := atomic.AddInt32(&serverCallCount, 1)
		w.Header().Set("Content-Type", "text/event-stream")
		if count <= 33 {
			_, _ = w.Write([]byte(formatPage(int(count), []any{
				map[string]any{"type": "arguments_delta", "name": "python", "callId": fmt.Sprintf("call-%d", count), "text": `{"code":"`},
			})))
		} else {
			_, _ = w.Write([]byte(formatPage(int(count), []any{
				map[string]any{"type": "reset"},
				map[string]any{"type": "message", "role": "assistant", "text": "recovered"},
			})))
		}
	}))
	defer server.Close()

	client := NewChatClient(ChatClientOptions{
		BaseURL: server.URL,
		AgentID: "session",
	})

	for i := 1; i < 33; i++ {
		_ = client.Stream(context.Background(), nil, func(event StreamEvent) error { return nil })
	}

	err := client.Stream(context.Background(), nil, func(event StreamEvent) error { return nil })
	if err == nil {
		t.Fatalf("expected error on call count limit, got: %v", err)
	}

	var events []StreamEvent
	_ = client.Stream(context.Background(), nil, func(event StreamEvent) error {
		events = append(events, event)
		return nil
	})

	lastURL := requestedURLs[len(requestedURLs)-1]
	if !strings.HasSuffix(lastURL, "after_seq=-1") {
		t.Fatalf("expected reconnect cursor reset to after_seq=-1, got: %s", lastURL)
	}
	if len(events) == 0 || events[len(events)-1].Text != "recovered" {
		t.Fatalf("expected recovered event, got: %+v", events)
	}
}

func TestDetachingDropsArgumentPreviews(t *testing.T) {
	var requestedURLs []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestedURLs = append(requestedURLs, r.URL.String())
		code := "old()"
		if len(requestedURLs) > 1 {
			code = "new()"
		}
		raw, _ := json.Marshal(map[string]any{"code": code})
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte(formatPage(len(requestedURLs), []any{
			map[string]any{"type": "arguments_delta", "name": "python", "callId": "same", "text": string(raw)},
		})))
	}))
	defer server.Close()

	client := NewChatClient(ChatClientOptions{
		BaseURL: server.URL,
		AgentID: "session",
	})

	ctx, cancel := context.WithCancel(context.Background())
	_ = client.Stream(ctx, nil, func(event StreamEvent) error {
		if event.Type == EventToolProgress && event.Progress != nil {
			cancel()
		}
		return nil
	})

	var events []StreamEvent
	_ = client.Stream(context.Background(), nil, func(event StreamEvent) error {
		events = append(events, event)
		return nil
	})

	if len(requestedURLs) < 2 || !strings.HasSuffix(requestedURLs[1], "after_seq=-1") {
		t.Fatalf("expected reconnect cursor reset to after_seq=-1, got: %+v", requestedURLs)
	}
	hasNew := false
	for _, ev := range events {
		if ev.Type == EventToolProgress && ev.Progress != nil && ev.Progress.Code != nil {
			if ev.Progress.Code.Text == "new()" {
				hasNew = true
				break
			}
		}
	}
	if !hasNew {
		t.Fatal("expected new() tool progress")
	}
}

func TestSnapshotEventsAreMarkedReplayed(t *testing.T) {
	pages := formatPage(2, []any{
		map[string]any{"type": "reset"},
		map[string]any{"type": "thinking", "text": "earlier"},
	}) + formatPage(3, []any{
		map[string]any{"type": "thinking", "text": "now"},
	})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte(pages))
	}))
	defer server.Close()
	client := NewChatClient(ChatClientOptions{BaseURL: server.URL, AgentID: "session"})
	replayed := map[string]bool{}
	_ = client.Stream(context.Background(), nil, func(event StreamEvent) error {
		if event.Type == EventThinking {
			replayed[event.Text] = event.Replayed
		}
		return nil
	})
	if !replayed["earlier"] || replayed["now"] {
		t.Fatalf("only the snapshot after a reset is history: %v", replayed)
	}
}
