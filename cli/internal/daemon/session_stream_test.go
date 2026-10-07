// Malformed replay batches must leave callbacks and cursors untouched.
// A controlled peer can inject these faults and unknown events into one stream.
package daemon

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
)

func TestSessionReplayRejectsWholeBatchAndRetainsCursor(t *testing.T) {
	for _, failure := range []string{"gap", "wrong cursor", "missing sequence", "malformed later event", "invalid invalidate", "changed generation", "malformed generation", "callback"} {
		t.Run(failure, func(t *testing.T) {
			var requests atomic.Int32
			callbackCause := errors.New("consumer stopped")
			conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/sessions/test" || r.Header.Get("Accept") != "text/event-stream" {
					t.Errorf("wrong subscription %s %s", r.URL, r.Header.Get("Accept"))
				}
				w.Header().Set("Content-Type", "text/event-stream")
				switch requests.Add(1) {
				case 1:
					writeInitialStream(w, "chat")
				case 2:
					if r.URL.Query().Get("after_seq") != "1" || r.URL.Query().Get("after_generation") != generationA {
						t.Errorf("lost resume cursor %s", r.URL)
					}
					generation := generationA
					cursor := int64(2)
					events := []any{canonicalText(2, "uncommitted")}
					switch failure {
					case "invalid invalidate":
						events = append(events, canonicalEvent("invalidate", 3, map[string]any{"kind": "unknown", "url": "/sessions/test"}))
						cursor = 3
					case "gap":
						events = []any{canonicalText(3, "gap")}
						cursor = 3
					case "wrong cursor":
						cursor = 3
					case "missing sequence":
						events = []any{map[string]any{"type": "text", "data": map[string]any{}}}
					case "malformed later event":
						events = append(events, canonicalEvent("status", 3, map[string]any{"phase": false, "run_id": nil, "interrupt_requested": false, "blocking_reason": nil}))
						cursor = 3
					case "changed generation":
						generation = generationB
					case "malformed generation":
						generation = "short"
					}
					writeBatch(w, map[string]any{"generation": generation, "cursor": cursor, "events": events})
				case 3:
					if r.URL.Query().Get("after_seq") != "1" {
						t.Errorf("rejected batch committed cursor %s", r.URL)
					}
					writeBatch(w, map[string]any{"generation": generationA, "cursor": 2, "events": []any{canonicalText(2, "replayed")}})
				}
			})
			client := NewChatClient(conn, "test")
			var texts []string
			callback := func(event StreamEvent) error {
				if event.Type == EventText {
					if failure == "callback" && event.Text == "uncommitted" {
						return callbackCause
					}
					texts = append(texts, event.Text)
				}
				return nil
			}
			if err := client.Stream(t.Context(), 0, callback); err != nil {
				t.Fatal(err)
			}
			err := client.Stream(t.Context(), 0, callback)
			if err == nil {
				t.Fatal("invalid batch delivered")
			}
			if failure == "callback" && !errors.Is(err, callbackCause) {
				t.Fatalf("callback cause lost %v", err)
			}
			if err = client.Stream(t.Context(), 0, callback); err != nil {
				t.Fatal(err)
			}
			if strings.Join(texts, ",") != "hello,replayed" {
				t.Fatalf("partial invalid batch reached client: %v", texts)
			}
		})
	}
}

func TestSessionUnknownEventsAdvanceCursorAndCancellationClearsIt(t *testing.T) {
	var requests atomic.Int32
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		switch requests.Add(1) {
		case 1:
			writeInitialStream(w, "chat")
			writeBatch(w, map[string]any{"generation": generationA, "cursor": 2, "events": []any{canonicalEvent("future", 2, map[string]any{})}})
		case 2:
			if r.URL.Query().Get("after_seq") != "2" {
				t.Errorf("unknown event cursor lost: %s", r.URL)
			}
			writeBatch(w, map[string]any{"generation": generationA, "cursor": 3, "events": []any{canonicalText(3, "cancel")}})
		case 3:
			if r.URL.Query().Has("after_seq") {
				t.Errorf("cancelled lifetime resumed: %s", r.URL)
			}
			writeInitialStream(w, "chat")
		}
	})
	client := NewChatClient(conn, "test")
	if err := client.Stream(t.Context(), 0, func(StreamEvent) error { return nil }); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	_ = client.Stream(ctx, 0, func(StreamEvent) error { cancel(); return context.Canceled })
	if err := client.Stream(t.Context(), 0, func(StreamEvent) error { return nil }); err != nil {
		t.Fatal(err)
	}
}

func TestResetProgressPrecedesLaterTerminalEvent(t *testing.T) {
	snapshot := canonicalSession("test", generationA, 0)
	snapshot["current_progress"] = []any{canonicalProgress("progress-a")}
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		writeBatch(w, map[string]any{"generation": generationA, "cursor": 1, "snapshot": snapshot, "events": []any{map[string]any{"type": "reset", "data": map[string]any{"reason": "initial"}}, canonicalEvent("tool_progress", 1, map[string]any{"progress": nil})}})
	})
	var progress []bool
	err := NewChatClient(conn, "test").Stream(t.Context(), 0, func(event StreamEvent) error {
		if event.Type == EventToolProgress {
			progress = append(progress, event.Progress != nil)
		}
		return nil
	})
	if err != nil || fmt.Sprint(progress) != "[true false]" {
		t.Fatalf("reset restored stale progress: %v %v", progress, err)
	}
}

func TestProgressOverflowIsRejectedBeforeCallbacks(t *testing.T) {
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		events := []any{map[string]any{"type": "reset", "data": map[string]any{"reason": "initial"}}}
		for i := range 33 {
			events = append(events, canonicalEvent("tool_progress", int64(i+1), map[string]any{"progress": canonicalProgress(fmt.Sprint(i))}))
		}
		events = append(events, canonicalEvent("tool_progress", 34, map[string]any{"progress": nil}))
		writeBatch(w, map[string]any{"generation": generationA, "cursor": 34, "snapshot": canonicalSession("test", generationA, 0), "events": events})
	})
	calls := 0
	err := NewChatClient(conn, "test").Stream(t.Context(), 0, func(StreamEvent) error { calls++; return nil })
	if err == nil || calls != 0 {
		t.Fatalf("intermediate overflow delivered: %v calls=%d", err, calls)
	}
}

// The daemon that restarts under a client is often an older build than the
// client, and older daemons end a stream with a daemon_unavailable failure
// batch while they shut down. The e2e suites run one build on both sides, so
// only this test sends that batch.
func TestFailureBatchFromStoppingDaemonIsTransient(t *testing.T) {
	for code, want := range map[string]StreamFailureKind{
		"daemon_unavailable":  StreamTransient,
		"daemon_stopping":     StreamTransient,
		"history_unavailable": StreamTerminal,
	} {
		client := NewChatClient(NewConnection(ConnectionSnapshot{Port: 1}, nil), "s")
		wire := `data: {"generation":"abcdefghijklmnopqrstuv","cursor":3,"events":[{"type":"failure","data":{"code":"` + code + `","detail":"gone"}}]}` + "\n\n"
		err := client.readStream(context.Background(), bufio.NewScanner(strings.NewReader(wire)), nil, func(StreamEvent) error { return nil })
		var failure *StreamError
		if !errors.As(err, &failure) || failure.Kind != want {
			t.Errorf("%s failure batch: %v, want kind %d", code, err, want)
		}
	}
}
