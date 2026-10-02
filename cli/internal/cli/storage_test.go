// Controlled peers return unsupported or malformed reports, and cancellation
// can interrupt a read. None of these failures may fall back to local storage.
package cli

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"albedo/cli/internal/app"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/storage"
)

func TestStorageCommandKeepsOnlineFailuresWithoutLocalFallback(t *testing.T) {
	for _, scenario := range []struct {
		name               string
		capabilities, body string
	}{
		{name: "unsupported", capabilities: `[]`},
		{name: "malformed", capabilities: `["storage_report"]`, body: `{"database":12}`},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			home := filepath.Join(t.TempDir(), "unreadable")
			if err := os.WriteFile(home, []byte("not a directory"), 0600); err != nil {
				t.Fatal(err)
			}
			reportCalls := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/health" {
					_, _ = w.Write([]byte(`{"ok":true,"version":2,"capabilities":` + scenario.capabilities + `}`))
					return
				}
				reportCalls++
				_, _ = w.Write([]byte(scenario.body))
			}))
			defer server.Close()
			conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
			defer conn.HTTPClient().CloseIdleConnections()
			application := &app.Service{Connect: func(context.Context) (*daemon.Connection, error) { t.Fatal("unexpected launch"); return nil, nil }, Existing: func(context.Context) (*daemon.Connection, error) { return conn, nil }}
			var output bytes.Buffer
			err := Execute(t.Context(), []string{"storage", "--json"}, Dependencies{Application: application, Storage: &storage.Service{Home: home, Now: time.Now}}, Streams{In: bytes.NewReader(nil), Out: &output, Err: io.Discard})
			if err == nil || output.Len() != 0 {
				t.Fatalf("failure delivered a report: %v %s", err, output.Bytes())
			}
			switch scenario.name {
			case "unsupported":
				if _, ok := errors.AsType[*daemon.UpgradeRequiredError](err); !ok {
					t.Fatalf("lost capability failure: %v", err)
				}
			case "malformed":
				if _, ok := errors.AsType[*daemon.ProtocolError](err); !ok {
					t.Fatalf("lost protocol failure: %v", err)
				}
			}
			if scenario.name == "unsupported" && reportCalls != 0 {
				t.Fatalf("dispatched unsupported report %d times", reportCalls)
			}
		})
	}
}

func TestStorageCommandCancellationDoesNotInspectLocalStorage(t *testing.T) {
	started := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			_, _ = w.Write([]byte(`{"ok":true,"version":2,"capabilities":["storage_report"]}`))
			return
		}
		close(started)
		<-r.Context().Done()
	}))
	defer server.Close()
	conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
	defer conn.HTTPClient().CloseIdleConnections()
	home := filepath.Join(t.TempDir(), "not-a-directory")
	if err := os.WriteFile(home, []byte("unreadable storage"), 0600); err != nil {
		t.Fatal(err)
	}
	application := &app.Service{Existing: func(ctx context.Context) (*daemon.Connection, error) { return conn, ctx.Err() }}
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	done := make(chan error, 1)
	var output bytes.Buffer
	go func() {
		done <- Execute(ctx, []string{"storage", "--json"}, Dependencies{Application: application, Storage: &storage.Service{Home: home, Now: time.Now}}, Streams{In: bytes.NewReader(nil), Out: &output, Err: io.Discard})
	}()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("report request never started")
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) || output.Len() != 0 {
			t.Fatalf("cancellation lost or returned a report: %v %s", err, output.Bytes())
		}
	case <-time.After(5 * time.Second):
		t.Fatal("storage report did not stop after cancellation")
	}
}
