package app

// Controlled streams verify turn membership, retries, and cleanup after cancellation.
import (
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/testwire"
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func promptTestConnection(server *httptest.Server) *daemon.Connection {
	return daemon.NewConnection(daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
}
func TestPromptRequiresDurableInputCapabilityBeforeCreatingASession(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/server" {
			t.Errorf("unsupported prompt issued %s", r.URL)
		}
		var resource map[string]any
		_ = json.Unmarshal([]byte(testwire.Server), &resource)
		resource["capabilities"] = map[string]any{}
		_ = json.NewEncoder(w).Encode(resource)
	}))
	defer server.Close()
	service := Service{Connect: func(ctx context.Context) (*daemon.Connection, error) {
		return daemon.Attach(ctx, daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "token"}, nil)
	}}
	_, err := service.RunPrompt(t.Context(), PromptOptions{Prompt: "hello"})
	if _, ok := errors.AsType[*daemon.CompatibilityError](err); !ok {
		t.Fatalf("missing capability dispatched a submission: %v", err)
	}
}
func promptEntry(id, text, run string, position int64) map[string]any {
	return map[string]any{"id": id, "position": position, "kind": "assistant", "created_at": nil, "input_id": nil, "turn_id": run, "checkpoint_id": nil, "content_complete": true, "content": []any{map[string]any{"kind": "text", "text": text}}, "tool": nil}
}
func TestPromptFollowsCombinedSubmissionThroughRetryAndCompletion(t *testing.T) {
	submitted := make(chan string, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == "PUT" && strings.HasPrefix(r.URL.Path, "/sessions/test/inputs/"):
			id := strings.TrimPrefix(r.URL.Path, "/sessions/test/inputs/")
			submitted <- id
			w.WriteHeader(202)
			_ = json.NewEncoder(w).Encode(testwire.Input("test", id, "message", "pending"))
		case r.URL.Path == "/sessions/test":
			w.Header().Set("Content-Type", "text/event-stream")
			testwire.WriteBatch(w, map[string]any{"generation": testwire.GenerationA, "cursor": 0, "snapshot": testwire.Session("test", testwire.GenerationA, 0), "events": []any{map[string]any{"type": "reset", "data": map[string]any{"reason": "initial"}}}})
			w.(http.Flusher).Flush()
			id := <-submitted
			input := testwire.Input("test", id, "message", "committed")
			input["turn"] = map[string]any{"id": "combined", "state": "running", "input_ids": []string{id, "other"}, "input_count": 2, "truncated": false, "started_at": "2026-10-03T00:00:00Z", "ended_at": nil, "outcome": nil}
			events := []any{testwire.Event("input", 1, map[string]any{"input": input}), testwire.Event("message", 2, map[string]any{"entry": promptEntry("m1", "before retry", "combined", 1)}), testwire.Event("error", 3, map[string]any{"run_id": "combined", "code": "temporary", "message": "temporary failure"}), testwire.Event("retry", 4, map[string]any{"run_id": "combined", "attempt": 2, "reason": map[string]any{"code": "retry", "detail": "retrying"}, "delay_ms": 0}), testwire.Event("message", 5, map[string]any{"entry": promptEntry("m2", "combined final answer", "combined", 2)}), testwire.Event("turn_completed", 6, map[string]any{"run_id": "combined", "state": "completed", "input_ids": []string{id, "other"}, "input_count": 2, "truncated": false})}
			testwire.WriteBatch(w, map[string]any{"generation": testwire.GenerationA, "cursor": 6, "events": events})
			w.(http.Flusher).Flush()
			<-r.Context().Done()
		default:
			t.Errorf("unexpected %s %s", r.Method, r.URL)
			w.WriteHeader(404)
		}
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	answer, err := awaitReply(ctx, daemon.NewChatClient(promptTestConnection(server), "test"), "hello")
	if err != nil || answer != "combined final answer" {
		t.Fatalf("combined reply: %q %v", answer, err)
	}
}
func TestPromptCancellationReportsSharedWorkAndCleanupFailure(t *testing.T) {
	for _, fixture := range []struct {
		name, outcome, want string
		status              int
	}{{"shared", "shared_running", "shared turn is still running", 200}, {"cleanup failure", "", "cancellation unconfirmed", 503}} {
		t.Run(fixture.name, func(t *testing.T) {
			submitted, cancelled := make(chan struct{}), make(chan struct{})
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch {
				case r.URL.Path == "/sessions/test":
					w.Header().Set("Content-Type", "text/event-stream")
					testwire.WriteBatch(w, map[string]any{"generation": testwire.GenerationA, "cursor": 0, "snapshot": testwire.Session("test", testwire.GenerationA, 0), "events": []any{map[string]any{"type": "reset", "data": map[string]any{"reason": "initial"}}}})
					w.(http.Flusher).Flush()
					<-r.Context().Done()
				case r.Method == "PUT" && strings.HasPrefix(r.URL.Path, "/sessions/test/inputs/"):
					id := strings.TrimPrefix(r.URL.Path, "/sessions/test/inputs/")
					w.WriteHeader(202)
					_ = json.NewEncoder(w).Encode(testwire.Input("test", id, "message", "pending"))
					close(submitted)
				case r.Method == "POST" && strings.HasSuffix(r.URL.Path, "/cancel"):
					if r.Context().Err() != nil {
						t.Error("cleanup reused cancelled context")
					}
					id := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/sessions/test/inputs/"), "/cancel")
					w.WriteHeader(fixture.status)
					_ = json.NewEncoder(w).Encode(map[string]any{"input": testwire.Input("test", id, "message", "committed"), "result": fixture.outcome})
					close(cancelled)
				default:
					t.Errorf("unexpected operation %s %s", r.Method, r.URL)
					w.WriteHeader(404)
				}
			}))
			defer server.Close()
			go func() { <-submitted; cancel() }()
			_, err := awaitReply(ctx, daemon.NewChatClient(promptTestConnection(server), "test"), "hello")
			if err == nil || !strings.Contains(err.Error(), fixture.want) {
				t.Fatalf("cancellation report %v", err)
			}
			select {
			case <-cancelled:
			default:
				t.Error("cleanup not attempted")
			}
		})
	}
}
