// Controlled cancellation and malformed wire batches cannot be forced reliably
// through a scripted provider; these tests exercise the public transport boundaries.
package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestEnsureHonorsCancellationDuringDiscoveryAndLockWait(t *testing.T) {
	for _, health := range []bool{false, true} {
		t.Run(fmt.Sprintf("stalled_health_%t", health), func(t *testing.T) {
			t.Setenv("ALBEDO_DAEMON", "")
			home := t.TempDir()
			if health {
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
				defer server.Close()
				writeDiscovery(t, home, ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "t", Version: 2})
			} else {
				if err := os.WriteFile(filepath.Join(home, "starting.lock"), fmt.Append(nil, os.Getpid()), 0600); err != nil {
					t.Fatal(err)
				}
			}
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
			defer cancel()
			started := time.Now()
			_, err := EnsureContext(ctx, home, "", nil)
			if !errors.Is(err, context.DeadlineExceeded) {
				t.Fatalf("deadline lost: %v", err)
			}
			if time.Since(started) > 300*time.Millisecond {
				t.Fatal("discovery or lock wait ignored caller deadline")
			}
		})
	}
}

func TestMalformedBatchDoesNotAdvanceCursorOrDeliverPartialEvents(t *testing.T) {
	client := NewChatClient(NewConnection(ConnectionSnapshot{}, ""), "s")
	delivered := 0
	scan := func(payload string) error {
		return client.readStream(context.Background(), bufio.NewScanner(strings.NewReader(payload)), func(event StreamEvent) error {
			if event.Type == EventText {
				delivered++
			}
			return nil
		})
	}
	if err := scan("data: {\"cursor\":7,\"events\":[{\"type\":\"text\",\"text\":\"ok\"}]}\n\n"); err != nil {
		t.Fatal(err)
	}
	if err := scan("data: {\"cursor\":8,\"events\":[{\"type\":\"text\",\"text\":\"partial\"},{\"type\":\"message\",\"text\":false}]}\n\n"); err == nil {
		t.Fatal("malformed known event accepted")
	}
	if client.afterSeq != 7 || delivered != 1 {
		t.Fatalf("malformed batch changed stream state: cursor=%d delivered=%d", client.afterSeq, delivered)
	}
	if err := scan("data: {\"cursor\":9,\"events\":[{\"type\":\"future\",\"text\":false}]}\n\n"); err != nil {
		t.Fatal(err)
	}
	if client.afterSeq != 9 || delivered != 1 {
		t.Fatal("unknown event should advance cursor without delivery")
	}
}

func TestTypedEventFormatsAndValidation(t *testing.T) {
	for _, body := range []string{
		`{"type":"turn_membership","turnId":"turn","submissionIds":["one","two"]}`,
		`{"type":"turn_completed","turnId":"turn"}`,
		`{"type":"tool","name":"python","args":"{\"code\":\"print(1)\"}","result":"1"}`,
		`{"type":"usage","promptTokens":10,"elapsedMs":1.5,"cacheFade":[{"at":1,"cached":2}]}`,
		`{"type":"tool_progress","progress":null}`,
	} {
		if _, err := decodeChatEvent(json.RawMessage(body)); err != nil {
			t.Fatalf("valid format %s: %v", body, err)
		}
	}
	for _, body := range []string{
		`{"type":"turn_membership","turnId":"turn","submissionIds":[1]}`,
		`{"type":"usage","promptTokens":"10"}`,
		`{"type":"thinking","text":"thought","elapsedMs":1.5}`,
		`{"type":"committed","seq":0}`,
		`{"type":"compacted","evicted":2}`,
	} {
		if _, err := decodeChatEvent(json.RawMessage(body)); err == nil {
			t.Fatalf("malformed event accepted: %s", body)
		}
	}
	event, err := decodeAgentEvent(json.RawMessage(`{"type":"mail","from":null,"fromName":"","to":"s","kind":"message","bytes":2}`))
	if err != nil || event == nil || event.To != "s" {
		t.Fatalf("nullable bus sender rejected: %v", err)
	}
	if _, err := decodeAgentEvent(json.RawMessage(`{"type":"running","session":"s","running":"false"}`)); err == nil {
		t.Fatal("malformed bus boolean accepted")
	}
}
