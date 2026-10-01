// Stream preview state across partial tool arguments, detach, and snapshot boundaries is race-prone and hard to force with a live daemon.
package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
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
	b := string(bData) + strings.Repeat(" ", 128)

	var requestCount atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count := requestCount.Add(1)
		w.Header().Set("Content-Type", "text/event-stream")
		switch count {
		case 1:
			_, _ = w.Write([]byte(formatPage(1, []any{
				map[string]any{"type": "arguments_delta", "name": "python", "callId": "a", "text": a},
				map[string]any{"type": "arguments_delta", "name": "python", "callId": "b", "text": b[:15]},
				map[string]any{"type": "tool", "callId": "a", "name": "python", "args": a, "result": "done"},
			})))
		case 2:
			http.Error(w, "temporarily unavailable", http.StatusServiceUnavailable)
		case 3:
			if r.URL.Query().Get("after_seq") != "1" {
				t.Error("transient failure discarded the reconnect cursor")
			}
			_, _ = w.Write([]byte(formatPage(2, []any{
				map[string]any{"type": "arguments_delta", "name": "python", "callId": "b", "text": b[15:16]},
			})))
		default:
			_, _ = w.Write([]byte(formatPage(3, []any{
				map[string]any{"type": "arguments_delta", "name": "python", "callId": "b", "text": b[16:]},
				map[string]any{"type": "tool_progress", "progress": map[string]any{"callId": "b", "name": "python", "phase": "running"}},
				map[string]any{"type": "tool", "callId": "b", "name": "python", "args": b, "result": "done"},
			})))
		}
	}))
	defer server.Close()

	conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, "")
	client := NewChatClient(conn, "session")

	var events []StreamEvent
	collect := func(event StreamEvent) error {
		if event.Type == EventToolProgress && event.Progress != nil && event.Progress.Phase == "running" {
			if _, exists := client.argumentsByCall[event.Progress.CallID]; exists {
				t.Error("running call still owns its argument buffer")
			}
		}
		events = append(events, event)
		return nil
	}
	_ = client.Stream(context.Background(), 0, collect)
	if _, exists := client.argumentsByCall["a"]; exists {
		t.Fatal("completed call still owns an argument buffer")
	}
	buffer := client.argumentsByCall["b"]
	if buffer == nil || client.afterSeq != 1 {
		t.Fatal("EOF discarded the unfinished call or cursor")
	}
	firstSnapshot := buffer.String()
	initialCapacity := buffer.Cap()
	if initialCapacity <= buffer.Len() {
		t.Fatal("fixture needs spare capacity to exercise an append without growth")
	}
	if err := client.Stream(context.Background(), 0, collect); err == nil {
		t.Fatal("expected transient HTTP failure")
	}
	if client.argumentsByCall["b"] != buffer || buffer.String() != firstSnapshot || client.afterSeq != 1 {
		t.Fatal("transient HTTP failure discarded unfinished arguments or cursor")
	}
	_ = client.Stream(context.Background(), 0, collect)
	secondSnapshot := buffer.String()
	if client.argumentsByCall["b"] != buffer || buffer.Cap() != initialCapacity || client.afterSeq != 2 {
		t.Fatal("reconnect did not continue the same buffer within its capacity")
	}
	_ = client.Stream(context.Background(), 0, collect)
	if buffer.Cap() <= initialCapacity {
		t.Fatal("fixture did not exercise buffer growth")
	}
	if firstSnapshot != b[:15] || secondSnapshot != b[:16] || buffer.String() != b {
		t.Fatal("appending or growing mutated retained argument snapshots")
	}
	if len(client.argumentsByCall) != 0 {
		t.Fatal("running and completed calls still own argument buffers")
	}

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
	var serverCallCount atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestedURLs = append(requestedURLs, r.URL.String())
		count := serverCallCount.Add(1)
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

	conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, "")
	client := NewChatClient(conn, "session")

	for range 32 {
		_ = client.Stream(context.Background(), 0, func(event StreamEvent) error { return nil })
	}

	err := client.Stream(context.Background(), 0, func(event StreamEvent) error { return nil })
	if err == nil {
		t.Fatalf("expected error on call count limit, got: %v", err)
	}

	var events []StreamEvent
	_ = client.Stream(context.Background(), 0, func(event StreamEvent) error {
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

func TestUnfinishedArgumentBytesBounded(t *testing.T) {
	const firstCallID = "first"
	const secondCallID = "second"
	firstArguments := strings.Repeat("x", 999_999)
	secondArguments := strings.Repeat("y", 2_000_000-len(firstCallID)-len(secondCallID)-len(firstArguments))
	var requestCount atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count := requestCount.Add(1)
		w.Header().Set("Content-Type", "text/event-stream")
		switch count {
		case 1:
			_, _ = w.Write([]byte(formatPage(1, []any{
				map[string]any{"type": "arguments_delta", "name": "other", "callId": firstCallID, "text": firstArguments},
				map[string]any{"type": "arguments_delta", "name": "other", "callId": secondCallID, "text": secondArguments},
			})))
		case 2:
			_, _ = w.Write([]byte(formatPage(2, []any{
				map[string]any{"type": "arguments_delta", "name": "other", "callId": secondCallID, "text": "!"},
			})))
		default:
			_, _ = w.Write([]byte(formatPage(3, []any{
				map[string]any{"type": "arguments_delta", "name": "other", "callId": firstCallID, "text": firstArguments},
				map[string]any{"type": "arguments_delta", "name": "other", "callId": secondCallID, "text": secondArguments + "!"},
			})))
		}
	}))
	defer server.Close()
	conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, "")
	client := NewChatClient(conn, "session")
	onEvent := func(StreamEvent) error { return nil }
	if err := client.Stream(context.Background(), 0, onEvent); err != nil {
		t.Fatalf("exact combined byte limit rejected: %v", err)
	}
	if len(client.argumentsByCall) != 2 || client.argumentsByCall[firstCallID].String() != firstArguments || client.argumentsByCall[secondCallID].String() != secondArguments {
		t.Fatal("exact limit did not retain both calls intact")
	}
	retainedSnapshot := client.argumentsByCall[secondCallID].String()
	if err := client.Stream(context.Background(), 0, onEvent); err == nil {
		t.Fatal("accepted one byte beyond the combined argument and call-ID limit")
	}
	if len(client.argumentsByCall) != 0 || client.afterSeq != -1 {
		t.Fatal("byte-limit failure retained argument buffers or cursor")
	}
	if retainedSnapshot != secondArguments {
		t.Fatal("overflow modified the retained argument snapshot")
	}
	if err := client.Stream(context.Background(), 0, onEvent); err == nil {
		t.Fatal("accepted one-byte overflow when adding a fresh call ID")
	}
	if len(client.argumentsByCall) != 0 || client.afterSeq != -1 {
		t.Fatal("fresh-call byte-limit failure retained argument buffers or cursor")
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

	conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, "")
	client := NewChatClient(conn, "session")

	ctx, cancel := context.WithCancel(context.Background())
	_ = client.Stream(ctx, 0, func(event StreamEvent) error {
		if event.Type == EventToolProgress && event.Progress != nil {
			cancel()
		}
		return nil
	})

	var events []StreamEvent
	_ = client.Stream(context.Background(), 0, func(event StreamEvent) error {
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
	conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, "")
	client := NewChatClient(conn, "session")
	replayed := map[string]bool{}
	_ = client.Stream(context.Background(), 0, func(event StreamEvent) error {
		if event.Type == EventThinking {
			replayed[event.Text] = event.Replayed
		}
		return nil
	})
	if !replayed["earlier"] || replayed["now"] {
		t.Fatalf("only the snapshot after a reset is history: %v", replayed)
	}
}
