// Controlled peers expose invalid batches and reconnect ordering that a conforming
// daemon cannot produce through an E2E provider.
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
	"testing"
	"time"
)

func formatSessionBatch(generation string, cursor int, events []any, currentProgress any, includeCurrentProgress bool) string {
	batch := map[string]any{"generation": generation, "cursor": cursor, "events": events}
	if includeCurrentProgress {
		batch["currentProgress"] = currentProgress
	}
	encoded, _ := json.Marshal(batch)
	return fmt.Sprintf("data: %s\n\n", encoded)
}

func TestResetDeliversNormalizedCurrentProgressAfterReplay(t *testing.T) {
	var requests int
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if serveNormalizedProgressHealth(writer, request) {
			return
		}
		writer.Header().Set("Content-Type", "text/event-stream")
		requests++
		if requests == 1 {
			_, _ = fmt.Fprint(writer, formatSessionBatch("g", 8, []any{
				map[string]any{"type": "reset"},
				map[string]any{"type": "message", "role": "assistant", "text": "durable"},
			}, []any{map[string]any{
				"callId": "run:2:1", "toolCallId": "native-7", "name": "python", "phase": "generating",
				"code": map[string]any{"offset": 3, "text": "é🙂"},
			}}, true))
			_, _ = fmt.Fprint(writer, formatSessionBatch("g", 9, []any{
				map[string]any{"type": "tool_progress", "progress": map[string]any{
					"callId": "run:2:1", "toolCallId": "native-7", "name": "python", "phase": "running",
				}},
				map[string]any{"type": "tool", "callId": "native-7", "progressCallId": "run:2:1", "name": "python", "args": "{}", "result": "done"},
			}, nil, false))
		}
	}))
	defer server.Close()
	client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
	var received []StreamEvent
	if err := client.Stream(t.Context(), 0, func(event StreamEvent) error {
		received = append(received, event)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if len(received) != 5 {
		t.Fatalf("received %d events, want reset, replay row, live snapshot, running, and result: %+v", len(received), received)
	}
	if received[0].Type != EventReset || !received[1].Replayed || received[1].Text != "durable" {
		t.Fatalf("durable snapshot order or replay marking changed: %+v", received[:2])
	}
	snapshot := received[2]
	if snapshot.Type != EventToolProgress || snapshot.Replayed || snapshot.Progress == nil || snapshot.Progress.CallID != "run:2:1" || snapshot.Progress.ToolCallID != "native-7" || snapshot.Progress.Code == nil || snapshot.Progress.Code.Offset != 3 || snapshot.Progress.Code.Text != "é🙂" {
		t.Fatalf("current progress snapshot was not delivered as live normalized progress: %+v", snapshot)
	}
	if received[3].Progress == nil || received[3].Progress.Phase != "running" || received[4].ProgressCallID != "run:2:1" {
		t.Fatalf("incremental progress and result correlation were lost: %+v", received[3:])
	}
}

func TestResetSnapshotIsValidatedBeforeCallbacksAndCursorCommit(t *testing.T) {
	tooManyCalls := make([]any, maxActiveToolProgress+1)
	for index := range tooManyCalls {
		tooManyCalls[index] = map[string]any{"callId": fmt.Sprintf("call-%d", index), "name": "python", "phase": "running"}
	}
	for name, progress := range map[string]any{
		"missing":             nil,
		"null":                json.RawMessage("null"),
		"invalid item":        []any{map[string]any{"callId": "c", "name": "python", "phase": "other"}},
		"too many scalars":    []any{map[string]any{"callId": "c", "name": "python", "phase": "generating", "code": map[string]any{"offset": 0, "text": strings.Repeat("x", 513)}}},
		"too many name bytes": []any{map[string]any{"callId": "c", "name": strings.Repeat("é", 51), "phase": "running"}},
		"oversized native id": []any{map[string]any{"callId": "c", "toolCallId": strings.Repeat("n", 201), "name": "python", "phase": "running"}},
		"oversized event":     []any{map[string]any{"callId": "c", "name": "python", "phase": "running", "extra": strings.Repeat("x", 8192)}},
		"too many calls":      tooManyCalls,
		"duplicate call id": []any{
			map[string]any{"callId": "c", "name": "python", "phase": "running"},
			map[string]any{"callId": "c", "name": "python", "phase": "generating"},
		},
	} {
		t.Run(name, func(t *testing.T) {
			var requests int
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				if serveNormalizedProgressHealth(writer, request) {
					return
				}
				writer.Header().Set("Content-Type", "text/event-stream")
				requests++
				if requests == 1 {
					_, _ = fmt.Fprint(writer, formatSessionBatch("g", 4, []any{map[string]any{"type": "reset"}, map[string]any{"type": "message", "role": "assistant", "text": "must not escape"}}, progress, name != "missing"))
					return
				}
				if request.URL.Query().Get("after_seq") != "" || request.URL.Query().Has("after_generation") {
					t.Errorf("invalid reset advanced cursor: %s", request.URL.RawQuery)
				}
				_, _ = fmt.Fprint(writer, formatSessionBatch("g", 5, []any{map[string]any{"type": "reset"}}, []any{}, true))
			}))
			defer server.Close()
			client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
			var delivered []StreamEvent
			err := client.Stream(t.Context(), 0, func(event StreamEvent) error {
				delivered = append(delivered, event)
				return nil
			})
			failure, ok := errors.AsType[*StreamError](err)
			if !ok || failure.Kind != StreamProtocol || len(delivered) != 0 {
				t.Fatalf("malformed reset snapshot escaped validation: err=%v delivered=%+v", err, delivered)
			}
			if err := client.Stream(t.Context(), 0, func(StreamEvent) error { return nil }); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestStreamDeliversProgressAtUnicodeLimits(t *testing.T) {
	name, nativeID, code := strings.Repeat("é", 50), strings.Repeat("n", 200), strings.Repeat("🙂", 512)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if serveNormalizedProgressHealth(writer, request) {
			return
		}
		writer.Header().Set("Content-Type", "text/event-stream")
		_, _ = fmt.Fprint(writer, formatSessionBatch("g", 1, []any{map[string]any{"type": "reset"}}, []any{
			map[string]any{"callId": "call", "toolCallId": nativeID, "name": name, "phase": "generating", "code": map[string]any{"offset": 13, "text": code}},
		}, true))
	}))
	defer server.Close()
	client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
	var delivered *ToolProgress
	if err := client.Stream(t.Context(), 0, func(event StreamEvent) error {
		if event.Type == EventToolProgress {
			delivered = event.Progress
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if delivered == nil || delivered.Name != name || delivered.ToolCallID != nativeID || delivered.Code == nil || delivered.Code.Text != code || delivered.Code.Offset != 13 {
		t.Fatalf("valid Unicode progress was rejected or changed: %+v", delivered)
	}
}

func TestResetSnapshotCallbackRunsBeforeCursorCommit(t *testing.T) {
	var requests int
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if serveNormalizedProgressHealth(writer, request) {
			return
		}
		writer.Header().Set("Content-Type", "text/event-stream")
		requests++
		if requests == 1 {
			_, _ = fmt.Fprint(writer, formatSessionBatch("g", 9, []any{map[string]any{"type": "reset"}}, []any{
				map[string]any{"callId": "run:1:0", "name": "python", "phase": "generating"},
			}, true))
			return
		}
		if request.URL.Query().Has("after_generation") || request.URL.Query().Has("after_seq") {
			t.Errorf("callback failure committed reset cursor: %s", request.URL.RawQuery)
		}
		_, _ = fmt.Fprint(writer, formatSessionBatch("g", 10, []any{map[string]any{"type": "reset"}}, []any{}, true))
	}))
	defer server.Close()
	client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
	stop := errors.New("stop after current progress")
	err := client.Stream(t.Context(), 0, func(event StreamEvent) error {
		if event.Type == EventToolProgress {
			return stop
		}
		return nil
	})
	if !errors.Is(err, stop) {
		t.Fatalf("snapshot callback failure was lost: %v", err)
	}
	if err := client.Stream(t.Context(), 0, func(StreamEvent) error { return nil }); err != nil {
		t.Fatal(err)
	}
}

func TestIncrementalProgressRequiresNormalizedEvents(t *testing.T) {
	for name, event := range map[string]any{
		"progress missing key":       map[string]any{"type": "tool_progress", "progress": map[string]any{"name": "python", "phase": "running"}},
		"result missing progress id": map[string]any{"type": "tool", "callId": "native", "name": "python", "args": "{}", "result": "done"},
	} {
		t.Run(name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				if serveNormalizedProgressHealth(writer, request) {
					return
				}
				writer.Header().Set("Content-Type", "text/event-stream")
				_, _ = fmt.Fprint(writer, formatSessionBatch("g", 2, []any{map[string]any{"type": "reset"}}, []any{}, true))
				_, _ = fmt.Fprint(writer, formatSessionBatch("g", 3, []any{event}, nil, false))
			}))
			defer server.Close()
			client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
			err := client.Stream(t.Context(), 0, func(StreamEvent) error { return nil })
			failure, ok := errors.AsType[*StreamError](err)
			if !ok || failure.Kind != StreamProtocol {
				t.Fatalf("non-normalized event was accepted: %v", err)
			}
		})
	}
}

func TestStreamCapabilityIsRequiredBeforeSubscription(t *testing.T) {
	var streamRequests int
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/health" {
			_, _ = fmt.Fprint(writer, `{"ok":true,"version":2,"capabilities":[]}`)
			return
		}
		streamRequests++
	}))
	defer server.Close()
	client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
	err := client.Stream(t.Context(), 0, func(StreamEvent) error { return nil })
	if _, ok := errors.AsType[*UpgradeRequiredError](err); !ok || streamRequests != 0 {
		t.Fatalf("stream opened without capability: err=%v requests=%d", err, streamRequests)
	}
}

func TestStreamCapabilityCheckHonorsCancellation(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if serveNormalizedProgressHealth(writer, request) {
			return
		}
		t.Error("stream opened after cancellation")
	}))
	defer server.Close()
	client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if err := client.Stream(ctx, 0, func(StreamEvent) error { return nil }); !errors.Is(err, context.Canceled) {
		t.Fatalf("capability preflight ignored cancellation: %v", err)
	}
}

func TestCancellationDuringCapabilityCheckClearsSavedCursor(t *testing.T) {
	healthStarted := make(chan struct{})
	var healthRequests, streamRequests int
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/health":
			healthRequests++
			if healthRequests == 2 {
				close(healthStarted)
				<-request.Context().Done()
				return
			}
			_, _ = fmt.Fprint(writer, `{"ok":true,"version":2,"capabilities":["normalized_tool_progress"]}`)
		case "/sessions/session/stream":
			streamRequests++
			writer.Header().Set("Content-Type", "text/event-stream")
			if streamRequests == 1 {
				_, _ = fmt.Fprint(writer, formatSessionBatch("saved", 12, []any{map[string]any{"type": "reset"}}, []any{
					map[string]any{"callId": "saved-call", "name": "python", "phase": "generating"},
				}, true))
				return
			}
			if request.URL.Query().Has("after_generation") || request.URL.Query().Has("after_seq") {
				t.Errorf("cancelled attachment retained its cursor: %s", request.URL.RawQuery)
			}
			_, _ = fmt.Fprint(writer, formatSessionBatch("fresh", 1, []any{map[string]any{"type": "reset"}}, []any{}, true))
		default:
			t.Errorf("unexpected request: %s", request.URL.Path)
		}
	}))
	defer server.Close()
	client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
	if err := client.Stream(t.Context(), 0, func(StreamEvent) error { return nil }); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	result := make(chan error, 1)
	go func() { result <- client.Stream(ctx, 0, func(StreamEvent) error { return nil }) }()
	select {
	case <-healthStarted:
	case <-time.After(5 * time.Second):
		t.Fatal("capability request did not start")
	}
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("cancelled capability request returned %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("capability request did not stop after cancellation")
	}
	if err := client.Stream(t.Context(), 0, func(StreamEvent) error { return nil }); err != nil {
		t.Fatal(err)
	}
}

func TestStreamRejectsIntermediateProgressOverflowBeforeDeliveryAndCursorCommit(t *testing.T) {
	var requests int
	var resumedCursor string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if serveNormalizedProgressHealth(w, r) {
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		requests++
		if requests == 1 {
			fmt.Fprint(w, formatSessionBatch("g", 7, []any{map[string]any{"type": "reset"}}, []any{}, true))
			events := make([]any, 0, 34)
			for i := range maxActiveToolProgress + 1 {
				events = append(events, map[string]any{"type": "tool_progress", "progress": map[string]any{"callId": fmt.Sprintf("c%d", i), "name": "python", "phase": "generating"}})
			}
			events = append(events, map[string]any{"type": "tool_progress", "progress": nil})
			fmt.Fprint(w, formatSessionBatch("g", 8, events, nil, false))
		} else {
			resumedCursor = r.URL.Query().Get("after_seq")
		}
	}))
	defer server.Close()
	c := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
	callbacks := 0
	err := c.Stream(t.Context(), 0, func(e StreamEvent) error {
		if e.Type == EventToolProgress {
			callbacks++
		}
		return nil
	})
	if err == nil {
		t.Error("accepted 33 active calls then clear")
	}
	if callbacks != 0 {
		t.Errorf("invalid batch delivered %d progress callbacks", callbacks)
	}
	if err := c.Stream(t.Context(), 0, func(StreamEvent) error { return nil }); err != nil {
		t.Fatal(err)
	}
	if resumedCursor != "7" {
		t.Errorf("reconnected after_seq=%q; want last valid cursor 7", resumedCursor)
	}
}

func TestTurnCompletionReleasesActiveProgressBeforeTheNextCall(t *testing.T) {
	var requests int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if serveNormalizedProgressHealth(w, r) {
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		requests++
		if requests > 1 {
			if r.URL.Query().Get("after_generation") != "g" || r.URL.Query().Get("after_seq") != "8" {
				t.Errorf("turn completion did not commit its cursor: %s", r.URL.RawQuery)
			}
			return
		}
		progress := make([]any, 0, maxActiveToolProgress)
		for index := range maxActiveToolProgress {
			progress = append(progress, map[string]any{"callId": fmt.Sprintf("old-%d", index), "name": "python", "phase": "running"})
		}
		fmt.Fprint(w, formatSessionBatch("g", 7, []any{map[string]any{"type": "reset"}}, progress, true))
		fmt.Fprint(w, formatSessionBatch("g", 8, []any{
			map[string]any{"type": "turn_completed", "turnId": "old-turn"},
			map[string]any{"type": "tool_progress", "progress": map[string]any{"callId": "fresh", "name": "python", "phase": "generating"}},
		}, nil, false))
	}))
	defer server.Close()
	client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
	var latest *ToolProgress
	if err := client.Stream(t.Context(), 0, func(event StreamEvent) error {
		if event.Type == EventToolProgress {
			latest = event.Progress
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if latest == nil || latest.CallID != "fresh" {
		t.Fatalf("completed turn retained obsolete progress: latest=%+v", latest)
	}
	if err := client.Stream(t.Context(), 0, func(StreamEvent) error { return nil }); err != nil {
		t.Fatal(err)
	}
}

func TestStreamRejectsMalformedCodeBeforeDeliveryAndKeepsReconnectCursor(t *testing.T) {
	for name, code := range map[string]any{
		"missing offset":    map[string]any{"text": "x"},
		"null offset":       map[string]any{"offset": nil, "text": "x"},
		"missing text":      map[string]any{"offset": 0},
		"null text":         map[string]any{"offset": 0, "text": nil},
		"string offset":     map[string]any{"offset": "0", "text": "x"},
		"fractional offset": map[string]any{"offset": 0.5, "text": "x"},
		"negative offset":   map[string]any{"offset": -1, "text": "x"},
		"number text":       map[string]any{"offset": 0, "text": 1},
		"array code":        []any{0, "x"},
	} {
		t.Run(name, func(t *testing.T) {
			var requests int
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if serveNormalizedProgressHealth(w, r) {
					return
				}
				w.Header().Set("Content-Type", "text/event-stream")
				requests++
				if requests == 1 {
					fmt.Fprint(w, formatSessionBatch("g", 7, []any{map[string]any{"type": "reset"}}, []any{}, true))
					fmt.Fprint(w, formatSessionBatch("g", 8, []any{
						map[string]any{"type": "text", "text": "must stay hidden"},
						map[string]any{"type": "tool_progress", "progress": map[string]any{"callId": "c", "name": "python", "phase": "generating", "code": code}},
					}, nil, false))
				} else if r.URL.Query().Get("after_seq") != "7" || r.URL.Query().Get("after_generation") != "g" {
					t.Errorf("malformed code advanced reconnect cursor: %s", r.URL.RawQuery)
				}
			}))
			defer server.Close()
			client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
			var delivered []StreamEvent
			err := client.Stream(t.Context(), 0, func(event StreamEvent) error { delivered = append(delivered, event); return nil })
			failure, ok := errors.AsType[*StreamError](err)
			if !ok || failure.Kind != StreamProtocol || len(delivered) != 1 || delivered[0].Type != EventReset {
				t.Fatalf("malformed code escaped validation: err=%v events=%+v", err, delivered)
			}
			if err := client.Stream(t.Context(), 0, func(StreamEvent) error { return nil }); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestRejectedBatchPreservesActiveCallIDsAndReconnectCursor(t *testing.T) {
	progress := func(call string) any {
		return map[string]any{"type": "tool_progress", "progress": map[string]any{"callId": call, "name": "python", "phase": "generating"}}
	}
	var requests int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if serveNormalizedProgressHealth(w, r) {
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		requests++
		if requests == 1 {
			var snapshot []any
			for i := range maxActiveToolProgress {
				snapshot = append(snapshot, map[string]any{"callId": fmt.Sprintf("c%d", i), "name": "python", "phase": "generating"})
			}
			fmt.Fprint(w, formatSessionBatch("g", 7, []any{map[string]any{"type": "reset"}}, snapshot, true))
			fmt.Fprint(w, formatSessionBatch("g", 8, []any{
				map[string]any{"type": "tool", "callId": "native", "progressCallId": "c0", "name": "python", "args": "{}", "result": "done"},
				progress("replacement"), progress("overflow"), map[string]any{"type": "tool_progress", "progress": nil},
			}, nil, false))
		} else {
			if r.URL.Query().Get("after_seq") != "7" || r.URL.Query().Get("after_generation") != "g" {
				t.Errorf("invalid batch advanced cursor: %s", r.URL.RawQuery)
			}
			// This insertion must still overflow the untouched 32-call snapshot.
			fmt.Fprint(w, formatSessionBatch("g", 8, []any{progress("new-call")}, nil, false))
		}
	}))
	defer server.Close()
	client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
	for attempt := range 2 {
		callbacks := 0
		err := client.Stream(t.Context(), 0, func(StreamEvent) error { callbacks++; return nil })
		failure, ok := errors.AsType[*StreamError](err)
		want := 0
		if attempt == 0 {
			want = 33
		}
		if !ok || failure.Kind != StreamProtocol || callbacks != want {
			t.Fatalf("rejected batch changed accepted state: attempt=%d err=%v callbacks=%d want=%d", attempt, err, callbacks, want)
		}
	}
}
