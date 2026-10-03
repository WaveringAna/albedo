// Controlled peers return unsupported or malformed reports, and cancellation
// can interrupt a read. None of these failures may fall back to local storage.
package cli

import (
	"bytes"
	"context"
	"encoding/json"
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
	"albedo/cli/internal/testwire"
)

func TestStorageCommandKeepsOnlineFailuresWithoutLocalFallback(t *testing.T) {
	for _, scenario := range []struct {
		name, body string
	}{
		{name: "unsupported"},
		{name: "malformed", body: `{"database":12}`},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			home := filepath.Join(t.TempDir(), "unreadable")
			if err := os.WriteFile(home, []byte("not a directory"), 0600); err != nil {
				t.Fatal(err)
			}
			reportCalls := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/server" {
					var resource map[string]any
					_ = json.Unmarshal([]byte(testwire.Server), &resource)
					capabilities := resource["capabilities"].(map[string]any)
					delete(capabilities, "storage_report")
					if scenario.name != "unsupported" {
						capabilities["storage_report"] = 1
					}
					_ = json.NewEncoder(w).Encode(resource)
					return
				}
				reportCalls++
				if scenario.name == "unsupported" {
					w.WriteHeader(404)
					_, _ = w.Write([]byte(`{"code":"not_found","detail":"Storage is unavailable"}`))
					return
				}
				_, _ = w.Write([]byte(scenario.body))
			}))
			defer server.Close()
			conn, attachErr := daemon.Attach(t.Context(), daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "token"}, nil)
			if attachErr != nil {
				t.Fatal(attachErr)
			}
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
		if r.URL.Path == "/server" {
			_, _ = w.Write([]byte(testwire.Server))
			return
		}
		close(started)
		<-r.Context().Done()
	}))
	defer server.Close()
	conn, attachErr := daemon.Attach(t.Context(), daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "token"}, nil)
	if attachErr != nil {
		t.Fatal(attachErr)
	}
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
