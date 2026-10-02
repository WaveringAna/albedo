// Discovery must distinguish an unsafe live endpoint from an absent daemon.
// Malformed records and deliberate health failures require controlled peers.
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

func writeDiscovery(t *testing.T, home string, snapshot ConnectionSnapshot) {
	t.Helper()
	data, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "daemon.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
}

// A real daemon normally exits before cancellation can reach the stop wait.
func TestUpgradeCancellationAfterShutdownDoesNotLaunchReplacement(t *testing.T) {
	if processAlive(0) {
		t.Skip("local process inspection is unsupported")
	}
	home := t.TempDir()
	executable := filepath.Join(t.TempDir(), "replacement")
	if err := os.WriteFile(executable, []byte("#!/bin/sh\n: > \"$ALBEDO_HOME/replacement-started\"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ALBEDO_DAEMON", executable)
	shutdownAcknowledged := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/health":
			_, _ = fmt.Fprint(w, healthyHealth)
		case "/shutdown":
			_, _ = fmt.Fprint(w, `{"ok":true}`)
			w.(http.Flusher).Flush()
			close(shutdownAcknowledged)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	snapshot := ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Pid: os.Getpid(), Token: "token", Version: ProtocolVersion, Build: "verified-build"}
	writeDiscovery(t, home, snapshot)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	finished := make(chan error, 1)
	go func() {
		_, err := Upgrade(ctx, LocalOptions{HomeDir: home}, snapshot)
		finished <- err
	}()
	select {
	case <-shutdownAcknowledged:
	case <-time.After(time.Second):
		t.Fatal("upgrade did not request shutdown")
	}
	// The acknowledged process deliberately remains alive, keeping Upgrade in
	// its exit wait until the caller cancels.
	select {
	case err := <-finished:
		t.Fatalf("upgrade returned before the live process exited: %v", err)
	case <-time.After(50 * time.Millisecond):
	}
	cancel()
	select {
	case err := <-finished:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("upgrade lost cancellation: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("upgrade did not cancel its exit wait")
	}
	if _, err := os.Stat(filepath.Join(home, "replacement-started")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("canceled upgrade launched a replacement: %v", err)
	}
}

func TestDiscoveryPreservesUnsafeRecordAndLiveHealthFailures(t *testing.T) {
	for _, status := range []int{http.StatusForbidden, http.StatusServiceUnavailable} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(status)
				_, _ = w.Write([]byte(`{"code":"authentication_required","error":"health refused"}`))
			}))
			defer server.Close()
			home := t.TempDir()
			writeDiscovery(t, home, ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Pid: os.Getpid(), Token: "token", Version: ProtocolVersion})
			_, err := Discover(t.Context(), home)
			failure, ok := errors.AsType[*LocalError](err)
			expected := UnhealthyDaemon
			if status == http.StatusForbidden {
				expected = AuthenticationFailed
			}
			api, hasAPI := errors.AsType[*APIError](err)
			if !ok || failure.Kind != expected || !hasAPI || api.StatusCode != status {
				t.Fatalf("health failure was treated as absence: %v", err)
			}
		})
	}
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, "daemon.json"), []byte(`{`), 0600); err != nil {
		t.Fatal(err)
	}
	_, err := Discover(t.Context(), home)
	failure, ok := errors.AsType[*LocalError](err)
	if !ok || failure.Kind != InvalidDiscovery {
		t.Fatalf("malformed record was treated as absence: %v", err)
	}
}
