// A login response can arrive after Bubble Tea has stopped. A controlled peer
// holds that response until actual terminal shutdown, which E2E cannot schedule.
package terminal

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"albedo/cli/internal/app"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/testwire"
)

func TestLoginProgramExitCancelsCreationCompletedAfterShutdown(t *testing.T) {
	started, cancelled := make(chan string, 1), make(chan string, 1)
	release := make(chan struct{})
	var releaseOnce sync.Once
	releaseLogin := func() { releaseOnce.Do(func() { close(release) }) }
	var opened, shutdown atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/server":
			_, _ = io.WriteString(w, testwire.Server)
		case r.URL.Path == "/settings":
			_ = json.NewEncoder(w).Encode(testwire.Settings())
		case r.URL.Path == "/auth":
			_, _ = io.WriteString(w, `{"providers":[{"id":"provider","label":"Provider","detail":"","flows":["browser"],"fields":[]}],"accounts":[]}`)
		case strings.HasPrefix(r.URL.Path, "/auth/logins/"):
			id := strings.TrimPrefix(r.URL.Path, "/auth/logins/")
			if r.Method == http.MethodDelete {
				cancelled <- id
				w.WriteHeader(http.StatusNoContent)
				return
			}
			if r.Method != http.MethodPut {
				t.Errorf("unexpected login request: %s", r.Method)
				http.Error(w, "unexpected", 500)
				return
			}
			started <- id
			<-release
			w.Header().Set("ETag", `"login-a"`)
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(map[string]any{"id": id, "provider": "provider", "url": "https://provider.example/login", "expires_at": "2099-01-01T00:00:00Z", "state": "waiting", "instructions": nil, "progress": "waiting", "accounts": []any{}, "failure": nil})
		case r.URL.Path == "/server/shutdown":
			shutdown.Store(true)
			http.Error(w, "unexpected shutdown", 500)
		default:
			t.Errorf("unexpected request: %s %s", r.Method, r.URL)
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)
	t.Cleanup(releaseLogin)
	conn, err := daemon.Attach(t.Context(), daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "token"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(conn.HTTPClient().CloseIdleConnections)
	input, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { input.Close(); writer.Close() })
	service := Service{In: input, Out: io.Discard, OpenBrowser: func(string) { opened.Store(true) }}
	ctx, cancel := context.WithCancel(t.Context())
	t.Cleanup(cancel)
	finished := make(chan error, 1)
	go func() { finished <- service.Login(ctx, app.PreparedOpen{Connection: conn}, "", "provider") }()
	var id string
	select {
	case id = <-started:
	case err := <-finished:
		t.Fatalf("login exited before creation began: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("login creation did not start")
	}
	cancel()
	select {
	case err := <-finished:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("program cancellation lost: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("program kept waiting for the held login response")
	}
	// The event loop has returned before the daemon finishes its admitted request.
	releaseLogin()
	select {
	case got := <-cancelled:
		if got != id {
			t.Fatalf("cancelled %q instead of the created login %q", got, id)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("late login creation survived terminal shutdown")
	}
	if opened.Load() || shutdown.Load() {
		t.Fatal("shutdown opened a browser or stopped the shared daemon")
	}
	if _, err := daemon.ProbeServer(t.Context(), conn); err != nil {
		t.Fatalf("shared daemon stopped responding: %v", err)
	}
}
