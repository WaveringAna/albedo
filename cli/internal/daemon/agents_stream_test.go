// Controlled peers can send malformed batches and data after overflow, which
// the daemon's agent bus cannot produce through the E2E provider.
package daemon

import (
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestAgentStreamReadinessAndOverflowStopDelivery(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
