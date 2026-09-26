package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func formatPage(cursor int, events []any) string {
	b, _ := json.Marshal(map[string]any{
		"cursor": cursor,
		"events": events,
	})
	return fmt.Sprintf("data: %s\n\n", string(b))
}

func TestSendQueuedState(t *testing.T) {
	var callCount int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count := atomic.AddInt32(&callCount, 1)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusAccepted)
		queued := count > 1
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "queued": queued})
	}))
	defer server.Close()

	client := NewChatClient(ChatClientOptions{
		BaseURL: server.URL,
		AgentID: "session",
	})

	res1, err := client.Send(context.Background(), "first", nil)
	if err != nil {
		t.Fatal(err)
	}
	if !res1.OK || res1.Queued {
		t.Fatalf("expected ok=true, queued=false, got: %+v", res1)
	}

	res2, err := client.Send(context.Background(), "steer", nil)
	if err != nil {
		t.Fatal(err)
	}
	if !res2.OK || !res2.Queued {
		t.Fatalf("expected ok=true, queued=true, got: %+v", res2)
	}
}

func TestStreamCompacted(t *testing.T) {
	page := formatPage(1, []any{
		map[string]any{"type": "compacted", "evicted": 12, "summary": "facts"},
		map[string]any{"type": "compacted", "evicted": -1, "summary": "no"},
		map[string]any{"type": "compacted", "evicted": 5, "summary": strings.Repeat("x", 60001)},
	})

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte(page))
	}))
	defer server.Close()

	client := NewChatClient(ChatClientOptions{
		BaseURL: server.URL,
		AgentID: "session",
	})

	var compacted []StreamEvent
	err := client.Stream(context.Background(), nil, func(event StreamEvent) error {
		if event.Type == EventCompacted {
			compacted = append(compacted, event)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}

	if len(compacted) != 1 {
		t.Fatalf("expected 1 compacted event, got %d", len(compacted))
	}
	if compacted[0].Evicted != 12 || compacted[0].Summary != "facts" {
		t.Fatalf("unexpected compacted event: %+v", compacted[0])
	}
}

func TestStreamThinkingDistinct(t *testing.T) {
	page := formatPage(1, []any{
		map[string]any{"type": "thinking", "text": "weighing options"},
		map[string]any{"type": "text", "text": "answer"},
		map[string]any{"type": "message", "role": "assistant", "text": "answer"},
	})

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte(page))
	}))
	defer server.Close()

	client := NewChatClient(ChatClientOptions{
		BaseURL: server.URL,
		AgentID: "session",
	})

	var events []StreamEvent
	err := client.Stream(context.Background(), nil, func(event StreamEvent) error {
		events = append(events, event)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}

	if len(events) != 3 {
		t.Fatalf("expected 3 events, got %d", len(events))
	}
	if events[0].Type != EventThinking || events[0].Text != "weighing options" {
		t.Fatalf("expected thinking event, got: %+v", events[0])
	}
	if events[1].Type != EventText || events[1].Text != "answer" {
		t.Fatalf("expected text event, got: %+v", events[1])
	}
	if events[2].Type != EventMessage || events[2].Text != "answer" {
		t.Fatalf("expected message event, got: %+v", events[2])
	}
}

func TestStreamPagesLivePythonPreviewsTraces(t *testing.T) {
	var requestedURLs []string
	code := "from pathlib import Path\nPath('demo.py').write_text('hello')"
	argsData, _ := json.Marshal(map[string]any{
		"code":       code,
		"timeout_ms": 1000,
	})
	args := string(argsData)

	frames := formatPage(1, []any{
		map[string]any{"type": "reset"},
		map[string]any{"type": "user", "text": "work", "source": "chat", "triggeredAt": ""},
	}) + formatPage(2, []any{
		map[string]any{"type": "arguments_delta", "callId": "call", "text": args[:40]},
	}) + formatPage(3, []any{
		map[string]any{"type": "arguments_delta", "callId": "call", "text": args[40:]},
	}) + formatPage(4, []any{
		map[string]any{
			"type":   "tool",
			"name":   "python",
			"args":   args,
			"result": "ok",
			"trace": map[string]any{
				"activities": []any{
					map[string]any{"kind": "read", "target": "demo.py"},
				},
				"changes": []any{},
			},
		},
		map[string]any{"type": "message", "role": "assistant", "text": "done"},
	})

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestedURLs = append(requestedURLs, r.URL.String())
		w.Header().Set("Content-Type", "text/event-stream")
		if len(requestedURLs) == 1 {
			_, _ = w.Write([]byte(frames))
		} else {
			_, _ = w.Write([]byte(formatPage(4, []any{})))
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

	if len(events) == 0 {
		t.Fatal("expected events")
	}
	if events[0].Type != EventReset {
		t.Fatalf("expected first event reset, got %s", events[0].Type)
	}

	hasProgressDemo := false
	for _, ev := range events {
		if ev.Type == EventToolProgress && ev.Progress != nil && ev.Progress.Code != nil {
			if strings.Contains(ev.Progress.Code.Text, "demo.py") {
				hasProgressDemo = true
				break
			}
		}
	}
	if !hasProgressDemo {
		t.Fatal("expected tool progress preview with demo.py")
	}

	var toolEvent *StreamEvent
	for i := range events {
		if events[i].Type == EventTool {
			toolEvent = &events[i]
			break
		}
	}
	if toolEvent == nil {
		t.Fatal("expected tool event")
	}
	if toolEvent.ToolArgs["code"] != code {
		t.Fatalf("expected tool arg code %s, got %v", code, toolEvent.ToolArgs["code"])
	}
	if toolEvent.ToolTrace == nil || len(toolEvent.ToolTrace.Activities) == 0 || toolEvent.ToolTrace.Activities[0].Target != "demo.py" {
		t.Fatalf("unexpected trace in tool event: %+v", toolEvent.ToolTrace)
	}

	last := events[len(events)-1]
	if last.Type != EventMessage || last.Text != "done" {
		t.Fatalf("expected last event message done, got %+v", last)
	}

	if len(requestedURLs) < 2 || !strings.HasSuffix(requestedURLs[1], "after_seq=4") {
		t.Fatalf("expected reconnect with after_seq=4, got: %+v", requestedURLs)
	}
}

func TestUsagePreservesOriginalRecordedAt(t *testing.T) {
	recordedAt := int64(1700000000000)
	page := formatPage(3, []any{
		map[string]any{"type": "reset"},
		map[string]any{
			"type":               "usage",
			"model":              "gpt-5",
			"promptTokens":       1000,
			"completionTokens":   100,
			"totalTokens":        1100,
			"cachedPromptTokens": 800,
			"recordedAt":         float64(recordedAt),
		},
	})

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte(page))
	}))
	defer server.Close()

	client := NewChatClient(ChatClientOptions{
		BaseURL: server.URL,
		AgentID: "session",
	})

	var usage *Usage
	_ = client.Stream(context.Background(), nil, func(event StreamEvent) error {
		if event.Type == EventUsage {
			usage = event.Usage
		}
		return nil
	})

	if usage == nil {
		t.Fatal("expected usage event")
	}
	if usage.Model != "gpt-5" || *usage.RecordedAt != recordedAt || *usage.CachedPromptTokens != 800 || *usage.PromptTokens != 1000 {
		t.Fatalf("unexpected usage: %+v", usage)
	}
}

func TestSendMissingWorkspaceError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusConflict)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"code":      "workspace_missing",
			"error":     "workspace not found",
			"workspace": "/gone",
		})
	}))
	defer server.Close()

	client := NewChatClient(ChatClientOptions{
		BaseURL: server.URL,
		AgentID: "session",
	})

	_, err := client.Send(context.Background(), "continue", nil)
	if err == nil {
		t.Fatal("expected error")
	}

	var wsErr *WorkspaceMissingError
	if !strings.Contains(err.Error(), "/gone") {
		t.Fatalf("expected /gone in error, got: %v", err)
	}
	_ = wsErr
}

func TestWorkspaceReplacementCapability(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if strings.HasSuffix(r.URL.Path, "/health") {
			_ = json.NewEncoder(w).Encode(map[string]any{
				"capabilities": []string{"session_workspace"},
			})
			return
		}
		if strings.HasSuffix(r.URL.Path, "/workspace") {
			_ = json.NewEncoder(w).Encode(map[string]any{
				"workspace": "/actual/workspace",
				"id":        "session",
			})
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer server.Close()

	client := NewChatClient(ChatClientOptions{
		BaseURL: server.URL,
		AgentID: "session",
	})

	update, err := client.ReplaceWorkspace(context.Background(), "/requested/workspace")
	if err != nil {
		t.Fatal(err)
	}
	if update.Workspace != "/actual/workspace" {
		t.Fatalf("expected /actual/workspace, got: %s", update.Workspace)
	}
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
				map[string]any{"type": "arguments_delta", "callId": "a", "text": a},
				map[string]any{"type": "arguments_delta", "callId": "b", "text": b[:15]},
				map[string]any{"type": "tool", "callId": "a", "name": "python", "args": a, "result": "done"},
			})))
		} else {
			_, _ = w.Write([]byte(formatPage(2, []any{
				map[string]any{"type": "arguments_delta", "callId": "b", "text": b[15:]},
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

func TestRunningProgressCarriesItsCode(t *testing.T) {
	running := func(code string) *ToolProgress {
		return parseStreamEvent(map[string]any{"type": "tool_progress", "progress": map[string]any{
			"callId": "c", "name": "python", "phase": "running",
			"code": map[string]any{"offset": 0.0, "text": code},
		}}).Progress
	}
	if p := running("\n  print(42)\nx = 1"); p.Intent != nil || p.Code == nil || p.Code.Text != "print(42)" {
		t.Fatalf("running call lost its first line: %+v", p)
	}
	if p := running("x = 1\nrun('go', 'test')"); p.Intent == nil || *p.Intent != (ToolIntent{Kind: "run", Target: "go test"}) {
		t.Fatalf("running call lost its intent: %+v", p)
	}
}

func TestMessageTimestampsSurvive(t *testing.T) {
	ts := int64(1700000000000)
	page := formatPage(1, []any{
		map[string]any{"type": "user", "text": "question", "source": "chat", "triggeredAt": "", "clientId": "sender", "timestamp": float64(ts)},
		map[string]any{"type": "message", "role": "assistant", "text": "answer", "timestamp": float64(ts + 1000)},
		map[string]any{"type": "message", "role": "assistant", "text": "answer"},
	})

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte(page))
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

	if len(events) != 3 {
		t.Fatalf("expected 3 events, got %d", len(events))
	}
	if events[0].Timestamp == nil || *events[0].Timestamp != ts {
		t.Fatalf("expected user timestamp %d, got %v", ts, events[0].Timestamp)
	}
	if events[1].Timestamp == nil || *events[1].Timestamp != ts+1000 {
		t.Fatalf("expected message timestamp %d, got %v", ts+1000, events[1].Timestamp)
	}
	if events[2].Timestamp != nil {
		t.Fatalf("expected nil timestamp for event 2, got %v", events[2].Timestamp)
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
				map[string]any{"type": "arguments_delta", "callId": fmt.Sprintf("call-%d", count), "text": `{"code":"`},
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
	if err == nil || !strings.Contains(err.Error(), "previews exceed client limit") {
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
			map[string]any{"type": "arguments_delta", "callId": "same", "text": string(raw)},
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

func TestCancelingAbortsPendingSendAndStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(100 * time.Millisecond)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("{}"))
	}))
	defer server.Close()

	client := NewChatClient(ChatClientOptions{
		BaseURL: server.URL,
		AgentID: "session",
	})

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	_, errSend := client.Send(ctx, "hello", nil)
	if errSend == nil {
		t.Fatal("expected error on cancelled send")
	}

	_, errStatus := client.GetStatus(ctx)
	if errStatus == nil {
		t.Fatal("expected error on cancelled getStatus")
	}
}

func TestSendCarriesBoundedImageAttachment(t *testing.T) {
	var receivedBody map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&receivedBody)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer server.Close()

	client := NewChatClient(ChatClientOptions{
		BaseURL:  server.URL,
		AgentID:  "session",
		ClientID: "sender",
	})

	img := &ImageAttachment{
		ImageMetadata: ImageMetadata{
			MimeType: ImagePNG,
			Width:    2,
			Height:   3,
			Bytes:    5,
		},
		Data: "aGVsbG8=",
	}

	_, err := client.Send(context.Background(), "describe", img)
	if err != nil {
		t.Fatal(err)
	}

	if receivedBody["content"] != "describe" || receivedBody["clientId"] != "sender" {
		t.Fatalf("unexpected body: %+v", receivedBody)
	}
	imgMap, ok := receivedBody["image"].(map[string]any)
	if !ok || imgMap["data"] != "aGVsbG8=" {
		t.Fatalf("unexpected image in body: %+v", receivedBody)
	}
}

func TestUserReplayAcceptsBoundedImageMetadata(t *testing.T) {
	page := formatPage(1, []any{
		map[string]any{
			"type": "user", "text": "one", "source": "chat", "triggeredAt": "",
			"image": map[string]any{"mimeType": "image/png", "width": 2, "height": 3, "bytes": 5},
		},
		map[string]any{
			"type": "user", "text": "two", "source": "chat", "triggeredAt": "",
			"image": map[string]any{"mimeType": "image/gif", "width": 2, "height": 3, "bytes": 5, "data": "secret"},
		},
	})

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte(page))
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

	if len(events) != 2 {
		t.Fatalf("expected 2 events, got %d", len(events))
	}
	if events[0].Image == nil || events[0].Image.MimeType != ImagePNG {
		t.Fatalf("expected valid png image for event 0: %+v", events[0])
	}
	if events[1].Image != nil {
		t.Fatalf("expected nil image for event 1 (gif dropped): %+v", events[1])
	}
}

func TestStreamEventNote(t *testing.T) {
	page := formatPage(1, []any{
		map[string]any{"type": "note", "text": "kernel idle timeout released"},
	})

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte(page))
	}))
	defer server.Close()

	client := NewChatClient(ChatClientOptions{
		BaseURL: server.URL,
		AgentID: "session",
	})

	var events []StreamEvent
	err := client.Stream(context.Background(), nil, func(event StreamEvent) error {
		events = append(events, event)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}

	if len(events) != 1 {
		t.Fatalf("expected 1 event, got %d", len(events))
	}
	if events[0].Type != EventNote || events[0].Text != "kernel idle timeout released" {
		t.Fatalf("expected EventNote, got %+v", events[0])
	}
}

func TestStreamCallbackErrorBackpressure(t *testing.T) {
	// Test onEvent error on reset
	resetPage := formatPage(1, []any{
		map[string]any{"type": "reset"},
		map[string]any{"type": "text", "text": "should not be reached"},
	})

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte(resetPage))
	}))
	defer server.Close()

	client := NewChatClient(ChatClientOptions{
		BaseURL: server.URL,
		AgentID: "session",
	})

	expectedErr := errors.New("ui aborted on reset")
	err := client.Stream(context.Background(), nil, func(event StreamEvent) error {
		if event.Type == EventReset {
			return expectedErr
		}
		return nil
	})

	if !errors.Is(err, expectedErr) {
		t.Fatalf("expected %v, got %v", expectedErr, err)
	}
}

func TestBoundedResponseExceeded(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(strings.Repeat("x", 70*1024)))
	}))
	defer server.Close()

	client := NewChatClient(ChatClientOptions{
		BaseURL: server.URL,
		AgentID: "session",
	})

	_, err := client.GetStatus(context.Background())
	if err == nil || !strings.Contains(err.Error(), "exceeded limit") {
		t.Fatalf("expected limit exceeded error, got: %v", err)
	}
}

func TestStreamProgressCallbackErrorBackpressure(t *testing.T) {
	deltaPage := formatPage(1, []any{
		map[string]any{"type": "arguments_delta", "callId": "call1", "text": `{"code":"read('foo')"`},
	})

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte(deltaPage))
	}))
	defer server.Close()

	client := NewChatClient(ChatClientOptions{
		BaseURL: server.URL,
		AgentID: "session",
	})

	expectedErr := errors.New("ui cancelled on progress")
	err := client.Stream(context.Background(), nil, func(event StreamEvent) error {
		if event.Type == EventToolProgress {
			return expectedErr
		}
		return nil
	})

	if !errors.Is(err, expectedErr) {
		t.Fatalf("expected %v, got %v", expectedErr, err)
	}
}

func TestContextWindowReadsThePreparedRequest(t *testing.T) {
	bodies := map[string]string{
		"known":   `{"state":"ready","model":"m","context_window_tokens":1048576,"sections":[]}`,
		"unknown": `{"state":"ready","model":"m","sections":[]}`,
		"pending": `{"state":"pending","reason":"no request yet"}`,
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/sessions/"), "/context")
		_, _ = w.Write([]byte(bodies[id]))
	}))
	defer server.Close()
	for id, want := range map[string]int{"known": 1048576, "unknown": 0, "pending": 0} {
		window, err := NewChatClient(ChatClientOptions{BaseURL: server.URL, AgentID: id}).ContextWindow(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if got := 0; window != nil {
			got = *window
			if got != want {
				t.Fatalf("%s: window %d, want %d", id, got, want)
			}
		} else if want != 0 {
			t.Fatalf("%s: no window, want %d", id, want)
		}
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

func TestChatClientContinue(t *testing.T) {
	var receivedPath string
	var receivedBody map[string]any

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		receivedPath = r.URL.Path
		_ = json.NewDecoder(r.Body).Decode(&receivedBody)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusAccepted)
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "queued": false})
	}))
	defer server.Close()

	client := NewChatClient(ChatClientOptions{
		BaseURL:  server.URL,
		AgentID:  "session-1",
		ClientID: "test-client",
	})

	res, err := client.Continue(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !res.OK {
		t.Fatal("expected OK true")
	}
	if receivedPath != "/sessions/session-1/events" {
		t.Fatalf("expected /sessions/session-1/events, got %s", receivedPath)
	}
	if receivedBody["type"] != "continue" {
		t.Fatalf("expected type continue, got %v", receivedBody)
	}
	if receivedBody["clientId"] != "test-client" {
		t.Fatalf("expected clientId test-client, got %v", receivedBody)
	}
}
