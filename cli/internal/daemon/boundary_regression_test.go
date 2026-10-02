// Controlled cancellation and malformed wire batches cannot be forced reliably
// through a scripted provider; these tests exercise the public transport boundaries.
package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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

func TestAgentEventsValidateNullableSendersAndBooleanFields(t *testing.T) {
	event, err := decodeAgentEvent(json.RawMessage(`{"type":"mail","from":null,"fromName":"","to":"s","kind":"message","bytes":2}`))
	if err != nil || event == nil || event.To != "s" {
		t.Fatalf("nullable bus sender rejected: %v", err)
	}
	if _, err := decodeAgentEvent(json.RawMessage(`{"type":"running","session":"s","running":"false"}`)); err == nil {
		t.Fatal("malformed bus boolean accepted")
	}
}
