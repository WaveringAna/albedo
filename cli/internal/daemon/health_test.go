// Malformed health and refresh races need controlled HTTP peers. The real
// daemon E2E verifies attachment and lifecycle behavior with valid health.
package daemon

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

const healthyHealth = `{"ok":true,"version":2,"capabilities":["operation_receipts","session_stream_generation","agents_stream_overflow"],"build":"verified-build"}`

// The restart offer stays quiet only for proven sameness: equal digests, or
// equal labels when digests are unavailable. Provable differences and
// unprovable ones both warrant offering a restart.
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

func TestAttachValidatesHealthBeforeReturningAConnection(t *testing.T) {
	for name, body := range map[string]string{
		"missing ok":                    `{"version":2,"capabilities":[]}`,
		"not ready":                     `{"ok":false,"version":2,"capabilities":[]}`,
		"fractional version":            `{"ok":true,"version":2.5,"capabilities":[]}`,
		"missing version":               `{"ok":true,"capabilities":[]}`,
		"nonpositive version":           `{"ok":true,"version":0,"capabilities":[]}`,
		"missing capabilities":          `{"ok":true,"version":2}`,
		"null capabilities":             `{"ok":true,"version":2,"capabilities":null}`,
		"null capability":               `{"ok":true,"version":2,"capabilities":[null]}`,
		"invalid capability":            `{"ok":true,"version":2,"capabilities":[false]}`,
		"invalid build":                 `{"ok":true,"version":2,"capabilities":[],"build":false}`,
		"null build":                    `{"ok":true,"version":2,"capabilities":[],"build":null}`,
		"invalid digest":                `{"ok":true,"version":2,"capabilities":[],"digest":7}`,
		"null digest":                   `{"ok":true,"version":2,"capabilities":[],"digest":null}`,
		"missing required capabilities": `{"ok":true,"version":2,"capabilities":[]}`,
		"unsupported protocol":          `{"ok":true,"version":3,"capabilities":["operation_receipts","session_stream_generation","agents_stream_overflow"]}`,
	} {
		t.Run(name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = fmt.Fprint(w, body) }))
			defer server.Close()
			attached, err := Attach(t.Context(), ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "token"}, nil)
			if attached != nil || err == nil {
				t.Fatalf("invalid health attached: %+v %v", attached, err)
			}
			if name == "missing required capabilities" || name == "unsupported protocol" {
				if _, ok := errors.AsType[*CompatibilityError](err); !ok {
					t.Fatalf("compatibility failure lost type: %v", err)
				}
			} else if _, ok := errors.AsType[*ProtocolError](err); !ok {
				t.Fatalf("malformed health lost type: %v", err)
			}
		})
	}
}

func TestProbeHealthPreservesAuthenticationAndCancellationWithoutRediscovery(t *testing.T) {
	for _, cancelProbe := range []bool{false, true} {
		t.Run(fmt.Sprint(cancelProbe), func(t *testing.T) {
			entered := make(chan struct{})
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				close(entered)
				if cancelProbe {
					<-r.Context().Done()
					return
				}
				w.WriteHeader(http.StatusForbidden)
				_, _ = fmt.Fprint(w, `{"code":"authentication_required","error":"invalid bearer"}`)
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
			go func() { _, err := ProbeHealth(ctx, conn); finished <- err }()
			select {
			case <-entered:
			case <-time.After(time.Second):
				t.Fatal("health request never started")
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
					if !ok || failure.StatusCode != http.StatusForbidden || failure.Code != "authentication_required" {
						t.Fatalf("authentication lost: %v", err)
					}
				}
			case <-time.After(time.Second):
				t.Fatal("health request ignored cancellation")
			}
			if rediscoveries.Load() != 0 {
				t.Fatal("health probe attempted rediscovery")
			}
		})
	}
}

func TestRefreshGateCancellationAndSuccessfulAttachment(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			_, _ = fmt.Fprint(w, healthyHealth)
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
	if conn.Version() != ProtocolVersion || conn.Build() != "verified-build" {
		t.Fatalf("attachment trusted unverified discovery: %+v", conn.Snapshot())
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
				if r.URL.Path == "/health" {
					_, _ = fmt.Fprint(w, `{"ok":true,"version":2,"capabilities":null}`)
					return
				}
				operations.Add(1)
				w.WriteHeader(http.StatusForbidden)
				_, _ = fmt.Fprint(w, `{"code":"authentication_required"}`)
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
					t.Fatalf("health failure hidden: %v", err)
				}
			} else if !errors.Is(err, cause) {
				t.Fatalf("discovery failure hidden: %v", err)
			}
			if operations.Load() != 1 || rediscoveries.Load() != 1 || conn.Token() != "old" {
				t.Fatalf("failed refresh changed endpoint or replayed: operations=%d rediscoveries=%d token=%s", operations.Load(), rediscoveries.Load(), conn.Token())
			}
		})
	}
}
