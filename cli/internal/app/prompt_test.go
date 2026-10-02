package app

// These protocol tests control stream/request ordering that real provider
// timing cannot guarantee, including a cleanup response after caller cancellation.
import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
)

func promptTestConnection(server *httptest.Server) *daemon.Connection {
	return daemon.NewConnection(daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, "")
}

func TestPromptRejectsAnOlderDaemonBeforeCreatingASession(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/health" {
			t.Errorf("unsupported prompt issued %s", request.URL.Path)
		}
		_, _ = writer.Write([]byte(`{"capabilities":[]}`))
	}))
	defer server.Close()
	service := Service{Connect: func(context.Context) (*daemon.Connection, error) { return promptTestConnection(server), nil }}
	_, err := service.RunPrompt(t.Context(), PromptOptions{Prompt: "hello"})
	if err == nil || !strings.Contains(err.Error(), "needs an update") {
		t.Fatalf("old daemon result: %v", err)
	}
}

func TestPromptFollowsCombinedSubmissionThroughRetryAndCompletion(t *testing.T) {
	submitted := make(chan string, 1)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/sessions/test/events":
			var payload struct {
				SubmissionID string `json:"submissionId"`
				OperationID  string `json:"operationId"`
			}
			if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
				t.Error(err)
				return
			}
			if payload.SubmissionID == "" {
				t.Error("missing submission ID")
			}
			submitted <- payload.SubmissionID
			writer.WriteHeader(http.StatusAccepted)
			_ = json.NewEncoder(writer).Encode(map[string]any{"ok": true, "queued": true, "operationId": payload.OperationID})
		case "/sessions/test/stream":
			_, _ = fmt.Fprint(writer, "data: {\"cursor\":0,\"events\":[{\"type\":\"reset\"}]}\n\n")
			writer.(http.Flusher).Flush()
			id := <-submitted
			events := []map[string]any{
				{"type": "turn_membership", "turnId": "combined", "submissionIds": []string{id, "other"}},
				{"type": "user", "clientId": "another-client", "text": "other contribution"},
				{"type": "message", "text": "before retry"},
				{"type": "error", "text": "temporary failure"},
				{"type": "retry"},
				{"type": "compacted", "evicted": 1, "summary": "summary"},
				{"type": "message", "text": "combined final answer"},
				{"type": "turn_completed", "turnId": "combined"},
				{"type": "turn_membership", "turnId": "later", "submissionIds": []string{"other"}},
				{"type": "message", "text": "later answer"},
			}
			page, _ := json.Marshal(map[string]any{"cursor": 1, "events": events})
			_, _ = fmt.Fprintf(writer, "data: %s\n\n", page)
			writer.(http.Flusher).Flush()
			<-request.Context().Done()
		default:
			t.Errorf("unexpected %s", request.URL.Path)
			writer.WriteHeader(http.StatusNotFound)
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
	}{
		{"shared", "shared_running", "shared turn is still running", 200},
		{"cleanup failure", "", "cancellation unconfirmed", 503},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			submitted := make(chan struct{})
			cancelled := make(chan struct{})
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				switch request.URL.Path {
				case "/sessions/test/events":
					var payload struct {
						OperationID string `json:"operationId"`
					}
					_ = json.NewDecoder(request.Body).Decode(&payload)
					writer.WriteHeader(http.StatusAccepted)
					_ = json.NewEncoder(writer).Encode(map[string]any{"ok": true, "queued": true, "operationId": payload.OperationID})
					close(submitted)
				case "/sessions/test/stream":
					_, _ = fmt.Fprint(writer, "data: {\"cursor\":0,\"events\":[{\"type\":\"reset\"}]}\n\n")
					writer.(http.Flusher).Flush()
					<-request.Context().Done()
				case "/sessions/test/cancel-submission":
					if request.Context().Err() != nil {
						t.Error("cleanup reused cancelled context")
					}
					writer.WriteHeader(fixture.status)
					_, _ = fmt.Fprintf(writer, `{"outcome":%q}`, fixture.outcome)
					close(cancelled)
				default:
					t.Errorf("unexpected operation: %s", request.URL.Path)
					writer.WriteHeader(404)
				}
			}))
			defer server.Close()
			go func() { <-submitted; cancel() }()
			_, err := awaitReply(ctx, daemon.NewChatClient(promptTestConnection(server), "test"), "hello")
			if err == nil || !strings.Contains(err.Error(), fixture.want) || strings.Contains(err.Error(), "stopped") {
				t.Fatalf("cancellation report: %v", err)
			}
			select {
			case <-cancelled:
			default:
				t.Error("cleanup not attempted")
			}
		})
	}
}
