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

func TestDiscoveryAndLauncherWaitHonorCancellation(t *testing.T) {
	for _, health := range []bool{false, true} {
		t.Run(fmt.Sprintf("stalled_health_%t", health), func(t *testing.T) {
			home := t.TempDir()
			var operation func(context.Context) error
			if health {
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
				defer server.Close()
				writeDiscovery(t, home, ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Pid: os.Getpid(), Token: "t", Version: ProtocolVersion})
				operation = func(ctx context.Context) error { _, err := Discover(ctx, home); return err }
			} else {
				if processAlive(0) {
					t.Skip("advisory locking requires Unix")
				}
				executable := filepath.Join(t.TempDir(), "unused-daemon")
				if err := os.WriteFile(executable, []byte("#!/bin/sh\nexit 99\n"), 0700); err != nil {
					t.Fatal(err)
				}
				t.Setenv("ALBEDO_DAEMON", executable)
				lock, err := acquireLauncher(t.Context(), home)
				if err != nil {
					t.Fatal(err)
				}
				defer lock.Close()
				operation = func(ctx context.Context) error { _, err := Launch(ctx, LocalOptions{HomeDir: home}); return err }
			}
			ctx, cancel := context.WithTimeout(t.Context(), 30*time.Millisecond)
			defer cancel()
			started := time.Now()
			if err := operation(ctx); !errors.Is(err, context.DeadlineExceeded) {
				t.Fatalf("deadline lost: %v", err)
			}
			if time.Since(started) > 300*time.Millisecond {
				t.Fatal("discovery or launcher wait ignored caller deadline")
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
