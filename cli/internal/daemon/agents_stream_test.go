// Controlled peers exercise delivery and failure behavior the real daemon cannot force deterministically.
package daemon

import (
	"fmt"
	"net/http"
	"testing"
)

func TestCollectionReadyOverflowAndAtomicValidation(t *testing.T) {
	for _, bad := range []bool{false, true} {
		t.Run(fmt.Sprint(bad), func(t *testing.T) {
			conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/sessions" || r.Header.Get("Accept") != "text/event-stream" {
					t.Errorf("wrong collection route %s", r.URL)
				}
				w.Header().Set("Content-Type", "text/event-stream")
				writeInitialStream(w, "agents")
				if bad {
					writeBatch(w, map[string]any{"events": []any{map[string]any{"type": "mail", "data": map[string]any{"mail_id": "m", "sender_session_id": nil, "sender_label": nil, "receiver_session_id": "s", "kind": "message", "bytes": 1}}, map[string]any{"type": "invalidate", "data": map[string]any{"urls": []any{}, "session_ids": []any{}, "scope_dirty": "false"}}}})
				} else {
					writeBatch(w, map[string]any{"events": []any{map[string]any{"type": "overflow", "data": map[string]any{}}}})
				}
			})
			batches := 0
			err := StreamAgents(t.Context(), conn, func([]AgentEvent) error { batches++; return nil })
			expected := 2
			if bad {
				expected = 1
			}
			if err == nil || batches != expected {
				t.Fatalf("collection delivery changed: %v batches=%d", err, batches)
			}
		})
	}
}
