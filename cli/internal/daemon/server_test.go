// Malformed server and refresh races need controlled HTTP peers. The real
// daemon E2E verifies attachment and lifecycle behavior with valid server.
package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

const readyServer = `{"instance_id":"instance-a","protocol":3,"state":"ready","capabilities":{"durable_inputs":1,"session_replay":1,"collection_invalidation":1,"tool_progress":1},"build":"verified-build","digest":"verified-digest","extensions":[],"quota":[],"notices":[]}`

func TestAttachValidatesServerIdentityAndRequiredCapabilities(t *testing.T) {
	for _, change := range []struct {
		name, key     string
		value         any
		compatibility bool
	}{
		{"missing identity", "instance_id", nil, false},
		{"fractional protocol", "protocol", 3.5, false},
		{"unsupported protocol", "protocol", 2, true},
		{"missing capabilities", "capabilities", nil, false},
		{"unsupported capability revision", "capabilities", map[string]any{}, true},
		{"draining daemon", "state", "draining", false},
		{"invalid digest", "digest", 7, false},
	} {
		t.Run(change.name, func(t *testing.T) {
			var resource map[string]any
			_ = json.Unmarshal([]byte(readyServer), &resource)
			resource[change.key] = change.value
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/server" {
					t.Errorf("unexpected route %s", r.URL.Path)
				}
				_ = json.NewEncoder(w).Encode(resource)
			}))
			defer server.Close()
			conn, err := Attach(t.Context(), ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "token"}, nil)
			if conn != nil || err == nil {
				t.Fatalf("invalid server attached: %v %v", conn, err)
			}
			if change.compatibility {
				if _, ok := errors.AsType[*CompatibilityError](err); !ok {
					t.Fatalf("compatibility cause lost: %v", err)
				}
			}
		})
	}
}

func TestOptionalCapabilitiesPreventRequestsWithoutRepeatedServerReads(t *testing.T) {
	for _, feature := range []struct {
		name string
		run  func(context.Context, *Connection) error
	}{
		{"context", func(ctx context.Context, conn *Connection) error {
			_, err := GetContextSnapshot(ctx, conn, "s")
			return err
		}},
		{"catalog", func(ctx context.Context, conn *Connection) error {
			_, err := GetCapabilityCatalog(ctx, conn, "s")
			return err
		}},
		{"workspace_browsing", func(ctx context.Context, conn *Connection) error {
			_, err := ListFolders(ctx, conn, "/workspace")
			return err
		}},
		{"host_probes", func(ctx context.Context, conn *Connection) error { _, err := WarmHost(ctx, conn, "target"); return err }},
		{"provider_auth", func(ctx context.Context, conn *Connection) error { _, err := SignInList(ctx, conn); return err }},
		{"storage_report", func(ctx context.Context, conn *Connection) error { _, err := GetStorageReport(ctx, conn); return err }},
	} {
		t.Run(feature.name, func(t *testing.T) {
			var serverReads, requests atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/server" {
					serverReads.Add(1)
					_, _ = w.Write([]byte(readyServer))
					return
				}
				requests.Add(1)
				w.WriteHeader(http.StatusNotFound)
			}))
			t.Cleanup(server.Close)
			conn, err := Attach(t.Context(), ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "token"}, nil)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(conn.HTTPClient().CloseIdleConnections)
			for range 2 {
				if _, ok := errors.AsType[*UpgradeRequiredError](feature.run(t.Context(), conn)); !ok {
					t.Fatal("the missing advertised optional capability was not refused")
				}
			}
			ctx, cancel := context.WithCancel(t.Context())
			cancel()
			if err := feature.run(ctx, conn); !errors.Is(err, context.Canceled) {
				t.Fatalf("caller cancellation was replaced by capability refusal: %v", err)
			}
			if serverReads.Load() != 1 || requests.Load() != 0 {
				t.Fatalf("capability checks issued HTTP requests: server=%d operation=%d", serverReads.Load(), requests.Load())
			}
		})
	}
}

func TestOptionalRecoveryUsesReplacementEndpointCapabilities(t *testing.T) {
	var replacementReads, replacementRequests atomic.Int32
	replacement := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/server" {
			replacementReads.Add(1)
			_, _ = w.Write([]byte(readyServer))
			return
		}
		replacementRequests.Add(1)
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(replacement.Close)
	var originalReads, originalRequests atomic.Int32
	original := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/server" {
			originalReads.Add(1)
			var resource map[string]any
			_ = json.Unmarshal([]byte(readyServer), &resource)
			resource["capabilities"].(map[string]any)["catalog"] = 1
			_ = json.NewEncoder(w).Encode(resource)
			return
		}
		originalRequests.Add(1)
		w.Header().Set("WWW-Authenticate", "Bearer")
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"type":"about:blank","title":"Unauthorized","status":401,"code":"authentication_required","detail":"expired bearer"}`))
	}))
	t.Cleanup(original.Close)
	next := ConnectionSnapshot{Port: replacement.Listener.Addr().(*net.TCPAddr).Port, Token: "replacement"}
	conn, err := Attach(t.Context(), ConnectionSnapshot{Port: original.Listener.Addr().(*net.TCPAddr).Port, Token: "original"}, func(context.Context) (ConnectionSnapshot, error) { return next, nil })
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(conn.HTTPClient().CloseIdleConnections)
	_, err = GetCapabilityCatalog(t.Context(), conn, "s")
	if _, ok := errors.AsType[*UpgradeRequiredError](err); !ok {
		t.Fatalf("replacement capability refusal was lost: %v", err)
	}
	endpoint := conn.Snapshot()
	if endpoint.Port != next.Port || endpoint.Token != next.Token || originalReads.Load() != 1 || originalRequests.Load() != 1 || replacementReads.Load() != 1 || replacementRequests.Load() != 0 {
		t.Fatalf("recovery reused old endpoint capability facts: old=%d/%d new=%d/%d", originalReads.Load(), originalRequests.Load(), replacementReads.Load(), replacementRequests.Load())
	}
}

func TestProbeServerPreservesAuthenticationAndCancellationWithoutRediscovery(t *testing.T) {
	for _, cancelProbe := range []bool{false, true} {
		t.Run(fmt.Sprint(cancelProbe), func(t *testing.T) {
			entered := make(chan struct{})
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				close(entered)
				if cancelProbe {
					<-r.Context().Done()
					return
				}
				w.WriteHeader(http.StatusUnauthorized)
				_, _ = fmt.Fprint(w, `{"type":"about:blank","title":"Unauthorized","status":401,"code":"authentication_required","detail":"invalid bearer"}`)
			}))
			defer server.Close()
			var rediscoveries atomic.Int32
			conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "old"}, func(context.Context) (ConnectionSnapshot, error) {
				rediscoveries.Add(1)
				return ConnectionSnapshot{}, errors.New("must not rediscover")
			})
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			finished := make(chan error, 1)
			go func() { _, err := ProbeServer(ctx, conn); finished <- err }()
			select {
			case <-entered:
			case <-time.After(time.Second):
				t.Fatal("server request never started")
			}
			if cancelProbe {
				cancel()
			}
			select {
			case err := <-finished:
				if cancelProbe {
					if !errors.Is(err, context.Canceled) {
						t.Fatalf("cancellation lost: %v", err)
					}
				} else {
					failure, ok := errors.AsType[*APIError](err)
					if !ok || failure.StatusCode != http.StatusUnauthorized || failure.Code != "authentication_required" {
						t.Fatalf("authentication lost: %v", err)
					}
				}
			case <-time.After(time.Second):
				t.Fatal("server request ignored cancellation")
			}
			if rediscoveries.Load() != 0 {
				t.Fatal("server probe attempted rediscovery")
			}
		})
	}
}

func TestRefreshGateCancellationAndSuccessfulAttachment(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/server" {
			_, _ = fmt.Fprint(w, readyServer)
			return
		}
		if r.Header.Get("Authorization") != "Bearer new" {
			t.Errorf("request used stale credential: %s", r.Header.Get("Authorization"))
		}
		_, _ = fmt.Fprint(w, `{"ok":true}`)
	}))
	defer server.Close()
	entered, release := make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	candidate := ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "new", Version: 99, Build: "unverified"}
	conn := NewConnection(ConnectionSnapshot{Port: candidate.Port, Token: "old"}, func(ctx context.Context) (ConnectionSnapshot, error) {
		calls.Add(1)
		close(entered)
		select {
		case <-release:
			return candidate, nil
		case <-ctx.Done():
			return ConnectionSnapshot{}, ctx.Err()
		}
	})
	defer conn.HTTPClient().CloseIdleConnections()
	finished := make(chan error, 1)
	go func() { finished <- conn.Refresh(t.Context()) }()
	<-entered
	waiting, cancel := context.WithCancel(t.Context())
	cancel()
	if err := conn.Refresh(waiting); !errors.Is(err, context.Canceled) {
		t.Fatalf("refresh wait cancellation lost: %v", err)
	}
	close(release)
	if err := <-finished; err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 {
		t.Fatalf("canceled waiter rediscovered: %d", calls.Load())
	}
	endpoint := conn.Snapshot()
	if endpoint.Version != ProtocolVersion || endpoint.Build != "verified-build" || endpoint.Digest != "verified-digest" {
		t.Fatalf("attachment trusted unverified discovery: %+v", endpoint)
	}
	if _, err := requestBytes(t.Context(), conn, operation{Name: "read", Method: http.MethodGet, Path: "/read", Policy: readRecovery}, responseLimits{bodyBytes: 50 * 1024 * 1024, errorBytes: 64 * 1024}); err != nil {
		t.Fatal(err)
	}
}

func TestOperationSurfacesRefreshFailureWithoutReplaying(t *testing.T) {
	for _, malformed := range []bool{false, true} {
		t.Run(fmt.Sprint(malformed), func(t *testing.T) {
			var operations, rediscoveries atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/server" {
					_, _ = fmt.Fprint(w, `{"instance_id":"bad","protocol":3,"capabilities":null}`)
					return
				}
				operations.Add(1)
				w.WriteHeader(http.StatusUnauthorized)
				_, _ = fmt.Fprint(w, `{"type":"about:blank","title":"Unauthorized","status":401,"code":"authentication_required","detail":"invalid bearer"}`)
			}))
			defer server.Close()
			cause := errors.New("discovery inaccessible")
			conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "old"}, func(context.Context) (ConnectionSnapshot, error) {
				rediscoveries.Add(1)
				if !malformed {
					return ConnectionSnapshot{}, cause
				}
				return ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "new"}, nil
			})
			_, err := requestBytes(t.Context(), conn, operation{Name: "change", Method: http.MethodPost, Path: "/mutation", Policy: authRecovery}, responseLimits{bodyBytes: 50 * 1024 * 1024, errorBytes: 64 * 1024})
			if malformed {
				if _, ok := errors.AsType[*ProtocolError](err); !ok {
					t.Fatalf("server failure hidden: %v", err)
				}
			} else if !errors.Is(err, cause) {
				t.Fatalf("discovery failure hidden: %v", err)
			}
			if operations.Load() != 1 || rediscoveries.Load() != 1 || conn.Snapshot().Token != "old" {
				t.Fatalf("failed refresh changed endpoint or replayed: operations=%d rediscoveries=%d token=%s", operations.Load(), rediscoveries.Load(), conn.Snapshot().Token)
			}
		})
	}
}

func TestBuildMismatchStaysQuietOnlyForProvenSameness(t *testing.T) {
	for _, tc := range []struct {
		running, selected BuildIdentity
		want              bool
	}{
		{running: BuildIdentity{Digest: "a"}, selected: BuildIdentity{Digest: "a"}},
		{running: BuildIdentity{Build: "same"}, selected: BuildIdentity{Build: "same"}},
		{running: BuildIdentity{Digest: "a"}, selected: BuildIdentity{Digest: "b"}, want: true},
		{running: BuildIdentity{Build: "x"}, selected: BuildIdentity{Build: "y"}, want: true},
		// Digests outrank labels: identical content is one build even when
		// the labels disagree, and different content is a mismatch even when
		// the labels agree.
		{running: BuildIdentity{Build: "old", Digest: "a"}, selected: BuildIdentity{Build: "new", Digest: "a"}},
		{running: BuildIdentity{Build: "same", Digest: "a"}, selected: BuildIdentity{Build: "same", Digest: "b"}, want: true},
		// Unprovable: one side of each identity is unknown.
		{running: BuildIdentity{Digest: "a"}, selected: BuildIdentity{Build: "y"}, want: true},
		{running: BuildIdentity{Build: "x"}, selected: BuildIdentity{Digest: "b"}, want: true},
		{want: true},
	} {
		if got := BuildMismatch(tc.running, tc.selected); got != tc.want {
			t.Fatalf("BuildMismatch(%+v, %+v) = %v, want %v", tc.running, tc.selected, got, tc.want)
		}
	}
}
