// Shutdown recovery must be checked through the Service caller: shared-daemon
// E2E cannot safely refuse shutdown while advertising replacement credentials.
package app

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"testing"

	"albedo/cli/internal/daemon"
)

func TestStopDaemonDoesNotRecoverAuthenticationRefusal(t *testing.T) {
	var shutdowns, healthProbes atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/shutdown":
			shutdowns.Add(1)
			if request.Method != http.MethodPost || request.Header.Get("Authorization") != "Bearer old" {
				t.Errorf("unexpected shutdown attempt: %s %q", request.Method, request.Header.Get("Authorization"))
			}
			writer.WriteHeader(http.StatusForbidden)
			_, _ = writer.Write([]byte(`{"code":"authentication_required","error":"invalid bearer"}`))
		case "/health":
			healthProbes.Add(1)
			_, _ = writer.Write([]byte(`{"version":2}`))
		default:
			t.Errorf("unexpected request %s", request.URL.Path)
			writer.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()
	_, portText, err := net.SplitHostPort(server.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		t.Fatal(err)
	}
	home := t.TempDir()
	replacement := daemon.ConnectionSnapshot{Port: port, Token: "new", Version: 2}
	record, err := json.Marshal(replacement)
	if err != nil {
		t.Fatal(err)
	}
	if writeErr := os.WriteFile(filepath.Join(home, "daemon.json"), record, 0600); writeErr != nil {
		t.Fatal(writeErr)
	}
	original := replacement
	original.Token = "old"
	conn := daemon.NewConnection(original, home)
	t.Cleanup(conn.HTTPClient().CloseIdleConnections)
	service := Service{Existing: func() (*daemon.Connection, error) { return conn, nil }}
	err = service.StopDaemon(context.Background())
	apiError, ok := errors.AsType[*daemon.APIError](err)
	if !ok || apiError.StatusCode != http.StatusForbidden {
		t.Fatalf("want original authentication rejection, got %v", err)
	}
	if shutdowns.Load() != 1 || healthProbes.Load() != 0 {
		t.Fatalf("shutdown was recovered: attempts=%d health probes=%d", shutdowns.Load(), healthProbes.Load())
	}
}
