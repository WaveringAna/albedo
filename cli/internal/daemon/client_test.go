// Controlled streams exercise preview assembly across EOF, cancellation, and
// reset boundaries that provider timing cannot reliably produce.
package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func formatPage(cursor int, events []any) string {
	batch, _ := json.Marshal(map[string]any{"generation": "generation-a", "cursor": cursor, "events": events})
	return fmt.Sprintf("data: %s\n\n", batch)
}

func TestToolPreviewContinuesAcrossEOFAndTransientFailure(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "text/event-stream")
		switch requests.Add(1) {
		case 1:
			_, _ = writer.Write([]byte(formatPage(1, []any{
				map[string]any{"type": "reset"},
				map[string]any{"type": "arguments_delta", "name": "python", "callId": "read", "text": `{"code":"read('first.py')"}`},
				map[string]any{"type": "tool", "callId": "read", "name": "python", "args": `{"code":"read('first.py')"}`, "result": "done"},
				map[string]any{"type": "arguments_delta", "name": "python", "callId": "edit", "text": `{"code":"edit('second`},
			})))
		case 2:
			writer.WriteHeader(http.StatusServiceUnavailable)
		case 3:
			if cursor := request.URL.Query().Get("after_seq"); cursor != "1" {
				t.Errorf("transient failure lost the consumed cursor: %s", cursor)
			}
			_, _ = writer.Write([]byte(formatPage(2, []any{
				map[string]any{"type": "arguments_delta", "name": "python", "callId": "edit", "text": `.py')"}`},
				map[string]any{"type": "tool_progress", "progress": map[string]any{"callId": "edit", "name": "python", "phase": "running"}},
				map[string]any{"type": "tool", "callId": "edit", "name": "python", "args": `{"code":"edit('second.py')"}`, "result": "done"},
			})))
		default:
			t.Errorf("unexpected automatic stream request: %s", request.URL)
		}
	}))
	defer server.Close()
	client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
	var previews []string
	var completed []string
	consume := func(event StreamEvent) error {
		if event.Type == EventToolProgress && event.Progress != nil && event.Progress.Code != nil {
			previews = append(previews, event.Progress.Code.Text)
		}
		if event.Type == EventTool {
			completed = append(completed, event.ToolResult)
		}
		return nil
	}
	if err := client.Stream(t.Context(), 0, consume); err != nil {
		t.Fatal(err)
	}
	err := client.Stream(t.Context(), 0, consume)
	failure, ok := errors.AsType[*StreamError](err)
	if !ok || failure.Kind != StreamTransient {
		t.Fatalf("server failure was not transient: %v", err)
	}
	if err := client.Stream(t.Context(), 0, consume); err != nil {
		t.Fatal(err)
	}
	if len(previews) != 3 || previews[0] != "read('first.py')" || previews[1] != "edit('second" || previews[2] != "edit('second.py')" {
		t.Fatalf("reconnect lost or mixed tool argument fragments: %q", previews)
	}
	if len(completed) != 2 {
		t.Fatalf("lost completed tool results: %v", completed)
	}
}

func TestStreamRejectsExcessUnfinishedCallsBeforeDeliveringTheBatch(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "text/event-stream")
		count := requests.Add(1)
		switch {
		case count <= 32:
			events := []any{map[string]any{"type": "arguments_delta", "name": "python", "callId": fmt.Sprintf("call-%d", count), "text": `{"code":"`}}
			if count == 1 {
				events = append([]any{map[string]any{"type": "reset"}}, events...)
			}
			_, _ = writer.Write([]byte(formatPage(int(count), events)))
		case count == 33:
			_, _ = writer.Write([]byte(formatPage(33, []any{
				map[string]any{"type": "text", "text": "must not escape"},
				map[string]any{"type": "arguments_delta", "name": "python", "callId": "excess-call", "text": `{"code":"`},
			})))
		case count == 34:
			if cursor := request.URL.Query().Get("after_seq"); cursor != "32" {
				t.Errorf("rejected batch advanced the cursor: %s", cursor)
			}
			_, _ = writer.Write([]byte(formatPage(32, []any{})))
		case count == 35:
			if cursor := request.URL.Query().Get("after_seq"); cursor != "" || request.URL.Query().Has("after_generation") {
				t.Errorf("recovery did not request a fresh snapshot: %s", cursor)
			}
			_, _ = writer.Write([]byte(formatPage(35, []any{
				map[string]any{"type": "reset"},
				map[string]any{"type": "message", "role": "assistant", "text": "recovered"},
			})))
		default:
			t.Error("unexpected stream request")
		}
	}))
	defer server.Close()
	client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
	consume := func(StreamEvent) error { return nil }
	for range 32 {
		if err := client.Stream(t.Context(), 0, consume); err != nil {
			t.Fatalf("accepted call rejected: %v", err)
		}
	}
	err := client.Stream(t.Context(), 0, func(StreamEvent) error { t.Error("oversized batch partially delivered"); return nil })
	failure, ok := errors.AsType[*StreamError](err)
	if !ok || failure.Kind != StreamProtocol {
		t.Fatalf("excess unfinished call did not fail protocol validation: %v", err)
	}
	if err := client.Stream(t.Context(), 0, consume); err != nil {
		t.Fatal(err)
	}
	client.ResetStream()
	var recovered bool
	if err := client.Stream(t.Context(), 0, func(event StreamEvent) error {
		recovered = recovered || event.Type == EventMessage && event.Text == "recovered" && event.Replayed
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if !recovered {
		t.Fatal("recovery did not deliver durable history")
	}
}

func TestStreamRejectsExcessArgumentBytesBeforeDeliveringTheBatch(t *testing.T) {
	firstArguments := strings.Repeat("x", 999_999)
	secondArguments := strings.Repeat("y", 2_000_000-len("first")-len("second")-len(firstArguments))
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "text/event-stream")
		switch requests.Add(1) {
		case 1:
			_, _ = writer.Write([]byte(formatPage(1, []any{
				map[string]any{"type": "reset"},
				map[string]any{"type": "arguments_delta", "name": "other", "callId": "first", "text": firstArguments},
				map[string]any{"type": "arguments_delta", "name": "other", "callId": "second", "text": secondArguments},
			})))
		case 2:
			_, _ = writer.Write([]byte(formatPage(2, []any{
				map[string]any{"type": "text", "text": "must not escape"},
				map[string]any{"type": "arguments_delta", "name": "other", "callId": "second", "text": "!"},
			})))
		case 3:
			if cursor := request.URL.Query().Get("after_seq"); cursor != "1" {
				t.Errorf("rejected byte overflow advanced the cursor: %s", cursor)
			}
			_, _ = writer.Write([]byte(formatPage(1, []any{})))
		case 4:
			_, _ = writer.Write([]byte(formatPage(3, []any{map[string]any{"type": "reset"}})))
			_, _ = writer.Write([]byte(formatPage(4, []any{
				map[string]any{"type": "text", "text": "must not escape"},
				map[string]any{"type": "arguments_delta", "name": "other", "callId": "first", "text": firstArguments},
				map[string]any{"type": "arguments_delta", "name": "other", "callId": "second", "text": secondArguments + "!"},
			})))
		case 5:
			if cursor := request.URL.Query().Get("after_seq"); cursor != "3" {
				t.Errorf("overflow lost the preceding successful reset: %s", cursor)
			}
			_, _ = writer.Write([]byte(formatPage(3, []any{})))
		default:
			t.Error("unexpected stream request")
		}
	}))
	defer server.Close()
	client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
	consume := func(StreamEvent) error { return nil }
	if err := client.Stream(t.Context(), 0, consume); err != nil {
		t.Fatalf("exact byte budget rejected: %v", err)
	}
	err := client.Stream(t.Context(), 0, func(StreamEvent) error { t.Error("overflowing batch partially delivered"); return nil })
	failure, ok := errors.AsType[*StreamError](err)
	if !ok || failure.Kind != StreamProtocol {
		t.Fatalf("existing call overflow was not a protocol failure: %v", err)
	}
	if err := client.Stream(t.Context(), 0, consume); err != nil {
		t.Fatal(err)
	}
	client.ResetStream()
	var delivered []EventType
	err = client.Stream(t.Context(), 0, func(event StreamEvent) error { delivered = append(delivered, event.Type); return nil })
	failure, ok = errors.AsType[*StreamError](err)
	if !ok || failure.Kind != StreamProtocol || len(delivered) != 1 || delivered[0] != EventReset {
		t.Fatalf("fresh call overflow leaked a partial batch: error=%v, events=%v", err, delivered)
	}
	if err := client.Stream(t.Context(), 0, consume); err != nil {
		t.Fatal(err)
	}
}

func TestCancellationStartsTheNextSubscriptionWithoutOldArguments(t *testing.T) {
	for _, beforeHeaders := range []bool{false, true} {
		name := "during event delivery"
		if beforeHeaders {
			name = "before response headers"
		}
		t.Run(name, func(t *testing.T) {
			var requests atomic.Int32
			waiting := make(chan struct{})
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				count := requests.Add(1)
				if beforeHeaders && count == 2 {
					close(waiting)
					<-request.Context().Done()
					return
				}
				writer.Header().Set("Content-Type", "text/event-stream")
				arguments := `{"code":"old`
				if count > 1 {
					if cursor := request.URL.Query().Get("after_seq"); cursor != "" || request.URL.Query().Has("after_generation") {
						t.Errorf("cancelled subscription retained its cursor: %s", cursor)
					}
					arguments = `{"code":"new()"}`
				}
				_, _ = writer.Write([]byte(formatPage(int(count), []any{
					map[string]any{"type": "reset"},
					map[string]any{"type": "arguments_delta", "name": "python", "callId": "same", "text": arguments},
				})))
			}))
			defer server.Close()
			client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			defer cancel()
			var err error
			if beforeHeaders {
				if err := client.Stream(t.Context(), 0, func(StreamEvent) error { return nil }); err != nil {
					t.Fatal(err)
				}
				finished := make(chan error, 1)
				go func() { finished <- client.Stream(ctx, 0, func(StreamEvent) error { return nil }) }()
				select {
				case <-waiting:
				case <-ctx.Done():
					t.Fatal("stream never requested response headers")
				}
				cancel()
				err = <-finished
			} else {
				err = client.Stream(ctx, 0, func(event StreamEvent) error {
					if event.Type == EventReset {
						return nil
					}
					cancel()
					return ctx.Err()
				})
			}
			if !errors.Is(err, context.Canceled) {
				t.Fatalf("cancellation cause lost: %v", err)
			}
			var preview string
			if err := client.Stream(t.Context(), 0, func(event StreamEvent) error {
				if event.Progress != nil && event.Progress.Code != nil {
					preview = event.Progress.Code.Text
				}
				return nil
			}); err != nil {
				t.Fatal(err)
			}
			if preview != "new()" {
				t.Fatalf("new subscription mixed old argument fragments: %q", preview)
			}
		})
	}
}

func TestSnapshotEventsAreMarkedReplayed(t *testing.T) {
	pages := formatPage(2, []any{
		map[string]any{"type": "reset"},
		map[string]any{"type": "thinking", "text": "earlier"},
	}) + formatPage(3, []any{map[string]any{"type": "thinking", "text": "now"}})
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "text/event-stream")
		_, _ = writer.Write([]byte(pages))
	}))
	defer server.Close()
	client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
	replayed := map[string]bool{}
	if err := client.Stream(t.Context(), 0, func(event StreamEvent) error {
		if event.Type == EventThinking {
			replayed[event.Text] = event.Replayed
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if len(replayed) != 2 || !replayed["earlier"] || replayed["now"] {
		t.Fatalf("only reset snapshot events should be replayed: %v", replayed)
	}
}
