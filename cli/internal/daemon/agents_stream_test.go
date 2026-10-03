// Controlled peers can send malformed batches and data after overflow, which
// the daemon's agent bus cannot produce through the E2E provider.
package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestAgentStreamReadinessAndOverflowStopDelivery(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if serveNormalizedProgressHealth(w, r) {
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, "data: "+`{"events":[]}`+"\n\n"+
			"data: "+`{"events":[]}`+"\n\n"+
			"data: "+`{"events":[{"type":"overflow"}]}`+"\n\n"+
			"data: "+`{"events":[{"type":"text","session":"s","text":"must stay hidden"}]}`+"\n\n")
	}))
	defer server.Close()
	conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
	var delivered [][]AgentEvent
	err := StreamAgents(t.Context(), conn, func(events []AgentEvent) error { delivered = append(delivered, events); return nil })
	if err != nil {
		t.Fatal(err)
	}
	if len(delivered) != 2 || len(delivered[0]) != 0 || len(delivered[1]) != 1 || delivered[1][0].Type != "overflow" {
		t.Fatalf("readiness or overflow delivery changed: %+v", delivered)
	}
}

func TestAgentStreamRejectsMalformedBatchBeforeDelivery(t *testing.T) {
	for name, batch := range map[string]string{
		"missing events": `{}`,
		"null events":    `{"events":null}`,
		"missing type":   `{"events":[{"session":"s"}]}`,
		"empty type":     `{"events":[{"type":""}]}`,
		"partial batch":  `{"events":[{"type":"text","session":"s","text":"must stay hidden"},{"type":"running","session":"s","running":"false"}]}`,
		"mixed overflow": `{"events":[{"type":"overflow"},{"type":"text","session":"s","text":"must stay hidden"}]}`,
	} {
		t.Run(name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if serveNormalizedProgressHealth(w, r) {
					return
				}
				w.Header().Set("Content-Type", "text/event-stream")
				_, _ = io.WriteString(w, "data: "+batch+"\n\n")
			}))
			defer server.Close()
			conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
			err := StreamAgents(t.Context(), conn, func([]AgentEvent) error { t.Error("malformed batch partially delivered"); return nil })
			failure, ok := errors.AsType[*StreamError](err)
			if !ok || failure.Kind != StreamProtocol {
				t.Fatalf("malformed batch classified incorrectly: %v", err)
			}
		})
	}
}

func TestAgentStreamRequiresNormalizedProgressCapability(t *testing.T) {
	var subscriptions int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			_, _ = io.WriteString(w, `{"ok":true,"version":2,"capabilities":[]}`)
			return
		}
		subscriptions++
	}))
	defer server.Close()
	conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
	err := StreamAgents(t.Context(), conn, func([]AgentEvent) error { t.Error("subscribed without capability"); return nil })
	if _, ok := errors.AsType[*UpgradeRequiredError](err); !ok || subscriptions != 0 {
		t.Fatalf("agent stream opened without normalized progress: err=%v subscriptions=%d", err, subscriptions)
	}
}

func TestAgentStreamKeepsOtherSessionsActiveAndRejectsIntermediateOverflow(t *testing.T) {
	progress := func(session, call string) any {
		return map[string]any{"type": "tool_progress", "session": session, "progress": map[string]any{"callId": call, "name": "python", "phase": "generating"}}
	}
	for name, middle := range map[string][]any{
		"text preserves all calls":        {map[string]any{"type": "text", "session": "a", "text": "hello"}},
		"other session finishes a call":   {map[string]any{"type": "tool", "session": "b", "name": "python", "callId": "native", "progressCallId": "c0", "output": "done"}, progress("b", "replacement")},
		"clear and replace other session": {map[string]any{"type": "tool_progress", "session": "b", "progress": nil}, progress("b", "replacement")},
		"same call update":                {progress("a", "c0")},
	} {
		t.Run(name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if serveNormalizedProgressHealth(w, r) {
					return
				}
				w.Header().Set("Content-Type", "text/event-stream")
				write := func(events []any) {
					batch, err := json.Marshal(map[string]any{"events": events})
					if err != nil {
						t.Error(err)
						return
					}
					fmt.Fprintf(w, "data: %s\n\n", batch)
				}
				var initial []any
				for _, session := range []string{"a", "b"} {
					for i := range maxActiveToolProgress {
						initial = append(initial, progress(session, fmt.Sprintf("c%d", i)))
					}
				}
				write(initial)
				write(middle)
				// Clearing after an invalid insertion cannot make its batch valid.
				write([]any{progress("a", "overflow"), map[string]any{"type": "tool_progress", "session": "a", "progress": nil}})
			}))
			defer server.Close()
			conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
			var delivered [][]AgentEvent
			err := StreamAgents(t.Context(), conn, func(events []AgentEvent) error { delivered = append(delivered, events); return nil })
			failure, ok := errors.AsType[*StreamError](err)
			if !ok || failure.Kind != StreamProtocol || len(delivered) != 2 || len(delivered[0]) != 64 || len(delivered[1]) != len(middle) {
				t.Fatalf("session progress changed or invalid insertion delivered: err=%v batches=%+v", err, delivered)
			}
		})
	}
}

func TestAgentStreamAcceptsCallReplacementAndTerminalCleanup(t *testing.T) {
	for _, terminal := range []string{"clear", "running", "error", "interrupted", "closed", "gone"} {
		t.Run(terminal, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if serveNormalizedProgressHealth(w, r) {
					return
				}
				w.Header().Set("Content-Type", "text/event-stream")
				progress := func(call string) any {
					return map[string]any{"type": "tool_progress", "session": "a", "progress": map[string]any{"callId": call, "name": "python", "phase": "running"}}
				}
				var initial []any
				for i := range maxActiveToolProgress {
					initial = append(initial, progress(fmt.Sprintf("c%d", i)))
				}
				cleanup := map[string]any{"type": terminal, "session": "a", "text": "ended", "running": false}
				if terminal == "clear" {
					cleanup = map[string]any{"type": "tool_progress", "session": "a", "progress": nil}
				}
				for _, events := range [][]any{initial, {
					map[string]any{"type": "tool", "session": "a", "name": "python", "callId": "native", "progressCallId": "c0", "output": "done"}, progress("replacement"),
				}, {cleanup, progress("after-cleanup")}} {
					encoded, err := json.Marshal(map[string]any{"events": events})
					if err != nil {
						t.Error(err)
						return
					}
					fmt.Fprintf(w, "data: %s\n\n", encoded)
				}
			}))
			defer server.Close()
			conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
			batches := 0
			if err := StreamAgents(t.Context(), conn, func([]AgentEvent) error { batches++; return nil }); err != nil || batches != 3 {
				t.Fatalf("replacement or terminal cleanup failed: batches=%d err=%v", batches, err)
			}
		})
	}
}
