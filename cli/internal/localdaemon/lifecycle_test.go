// Discovery must distinguish an unsafe live endpoint from an absent daemon.
// Malformed records and deliberate health failures require controlled peers.
package localdaemon

import (
	"albedo/cli/internal/daemon"
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

const readyServer = `{"instance_id":"instance-a","protocol":3,"state":"ready","capabilities":{"durable_inputs":1,"session_replay":2,"collection_invalidation":1,"tool_progress":1},"build":"verified-build","digest":"verified-digest","extensions":[],"quota":[],"notices":[]}`

func writeDiscovery(t *testing.T, home string, snapshot daemon.ConnectionSnapshot) {
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
		case "/server":
			_, _ = fmt.Fprint(w, readyServer)
		case "/server/shutdown":
			w.WriteHeader(202)
			_, _ = fmt.Fprint(w, `{"instance_id":"instance-a","state":"draining"}`)
			w.(http.Flusher).Flush()
			close(shutdownAcknowledged)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	snapshot := daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Pid: os.Getpid(), Token: "token", Version: daemon.ProtocolVersion, Build: "verified-build", Digest: "verified-digest", InstanceID: "instance-a"}
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
	t.Run("loaded healthy daemon", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Owner observations may queue behind work on an already ready daemon.
			timer := time.NewTimer(750 * time.Millisecond)
			defer timer.Stop()
			select {
			case <-timer.C:
				_, _ = fmt.Fprint(w, readyServer)
			case <-r.Context().Done():
			}
		}))
		defer server.Close()
		home := t.TempDir()
		snapshot := daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Pid: os.Getpid(), Token: "token", Version: daemon.ProtocolVersion, Build: "verified-build", InstanceID: "instance-a"}
		writeDiscovery(t, home, snapshot)
		// The live resource supplies verified build metadata missing from the record.
		snapshot.Digest = "verified-digest"
		discovery, err := Discover(t.Context(), home)
		if err != nil || discovery.Kind != Running || discovery.Snapshot != snapshot || discovery.Server.State != "ready" {
			t.Fatalf("loaded healthy daemon was not usable: %+v, %v", discovery, err)
		}
	})
	for _, status := range []int{http.StatusOK, http.StatusNotFound, http.StatusUnauthorized, http.StatusServiceUnavailable} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(status)
				if status == http.StatusOK {
					_, _ = w.Write([]byte(`{`))
					return
				}
				_, _ = w.Write([]byte(`{"type":"about:blank","title":"Unauthorized","status":401,"code":"authentication_required","detail":"health refused"}`))
			}))
			defer server.Close()
			home := t.TempDir()
			writeDiscovery(t, home, daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Pid: os.Getpid(), Token: "token", Version: daemon.ProtocolVersion})
			_, err := Discover(t.Context(), home)
			failure, ok := errors.AsType[*LocalError](err)
			expected := UnhealthyDaemon
			if status == http.StatusUnauthorized {
				expected = AuthenticationFailed
			}
			if !ok || failure.Kind != expected {
				t.Fatalf("health failure was treated as absence: %v", err)
			}
			if status == http.StatusOK {
				if _, ok := errors.AsType[*daemon.ProtocolError](err); !ok {
					t.Fatalf("malformed health lost its protocol failure: %v", err)
				}
			} else if api, ok := errors.AsType[*daemon.APIError](err); !ok || api.StatusCode != status {
				t.Fatalf("health failure lost its HTTP status: %v", err)
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

func TestDiscoveryRejectsChangedBuildDigest(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = fmt.Fprint(w, readyServer)
	}))
	t.Cleanup(server.Close)
	home := t.TempDir()
	writeDiscovery(t, home, daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Pid: os.Getpid(), Token: "token", Version: daemon.ProtocolVersion, Build: "verified-build", Digest: "different-digest"})
	found, err := Discover(t.Context(), home)
	local, ok := errors.AsType[*LocalError](err)
	if !ok || local.Kind != InvalidDiscovery || found.Kind == Running {
		t.Fatalf("changed executable identity accepted: %+v, %v", found, err)
	}
}

// A protocol 2 daemon has no /server route; the current daemon cannot produce
// this response, so a controlled peer checks migration diagnostics and refusal.
func TestDiscoveryExplainsOlderProtocolWithoutTreatingItAsReady(t *testing.T) {
	for _, status := range []int{http.StatusNotFound, http.StatusUnauthorized, http.StatusServiceUnavailable} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodGet || r.URL.Path != "/server" || r.Header.Get("Authorization") != "Bearer token" {
					t.Errorf("unexpected request while diagnosing an old daemon: %s %s", r.Method, r.URL.Path)
				}
				w.WriteHeader(status)
			}))
			t.Cleanup(server.Close)
			home := t.TempDir()
			snapshot := daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Pid: os.Getpid(), Token: "token", Version: 2}
			writeDiscovery(t, home, snapshot)
			found, err := Discover(t.Context(), home)
			failure, ok := errors.AsType[*LocalError](err)
			expected := UnhealthyDaemon
			switch status {
			case http.StatusNotFound:
				expected = IncompatibleDaemon
			case http.StatusUnauthorized:
				expected = AuthenticationFailed
			}
			if !ok || failure.Kind != expected || found.Kind == Running {
				t.Fatalf("old discovery record authorized attachment or lost its failure: %+v, %v", found, err)
			}
			if status == http.StatusNotFound {
				compatibility, ok := errors.AsType[*daemon.CompatibilityError](err)
				if !ok || compatibility.Version != 2 || !strings.Contains(err.Error(), "matching client (albedo daemon --stop)") {
					t.Fatalf("missing actionable protocol mismatch: %v", err)
				}
			}
			data, readErr := os.ReadFile(filepath.Join(home, "daemon.json"))
			var retained daemon.ConnectionSnapshot
			if readErr != nil || json.Unmarshal(data, &retained) != nil || retained != snapshot {
				t.Fatal("discovery changed the old daemon record")
			}
		})
	}
}

func TestDiscoveryAndLauncherWaitHonorCancellation(t *testing.T) {
	for _, health := range []bool{false, true} {
		t.Run(fmt.Sprintf("stalled_health_%t", health), func(t *testing.T) {
			home := t.TempDir()
			var operation func(context.Context) error
			if health {
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
				defer server.Close()
				writeDiscovery(t, home, daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Pid: os.Getpid(), Token: "t", Version: daemon.ProtocolVersion})
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
