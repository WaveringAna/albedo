// An already-open CLI client must reconnect after the daemon changes port and token; E2E restart opens fresh clients.
package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
)

func parsePort(urlStr string) int {
	parts := strings.Split(urlStr, ":")
	portStr := parts[len(parts)-1]
	p, _ := strconv.Atoi(portStr)
	return p
}

func writeDaemonRecord(t *testing.T, dir string, port int, token string) {
	t.Helper()
	conn := ConnectionSnapshot{
		Port:    port,
		Token:   token,
		Pid:     os.Getpid(),
		Version: 2,
	}
	data, err := json.Marshal(conn)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "daemon.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
}

// TestChatClientSendReconnectsAfterDaemonRestart verifies that when a daemon restarts
// on a new port with a new token, an open ChatClient's Send() call discovers the new
// daemon from daemon.json, updates the shared connection, and succeeds.

func TestChatClientSendReconnectsAfterDaemonRestart(t *testing.T) {
	tempDir := t.TempDir()

	var d1Received atomic.Int32
	d1 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer token-1" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		if r.URL.Path == "/health" {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"ok":true,"version":2}`))
			return
		}
		if r.URL.Path == "/sessions/sess-1/events" {
			d1Received.Add(1)
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"ok":true}`))
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))

	port1 := parsePort(d1.URL)
	writeDaemonRecord(t, tempDir, port1, "token-1")

	conn, err := Existing(tempDir)
	if err != nil || conn == nil {
		t.Fatalf("failed to get existing conn: %v", err)
	}

	client := NewChatClient(ChatClientOptions{
		AgentID: "sess-1",
		Conn:    conn,
	})

	// First send goes to daemon 1
	res, err := client.Send(context.Background(), "hello 1", nil)
	if err != nil || res == nil || !res.OK {
		t.Fatalf("first send failed: %v", err)
	}
	if d1Received.Load() != 1 {
		t.Fatalf("expected 1 turn on daemon 1, got %d", d1Received.Load())
	}

	// Daemon 1 shuts down!
	d1.Close()

	// Daemon 2 starts on a new port with a new token
	var d2Received atomic.Int32
	d2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer token-2" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		if r.URL.Path == "/health" {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"ok":true,"version":2}`))
			return
		}
		if r.URL.Path == "/sessions/sess-1/events" {
			d2Received.Add(1)
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"ok":true}`))
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer d2.Close()

	port2 := parsePort(d2.URL)
	writeDaemonRecord(t, tempDir, port2, "token-2")

	// Now client.Send is called! It should detect daemon 1 is gone,
	// find daemon 2 via daemon.json, update conn, and succeed.
	res, err = client.Send(context.Background(), "hello 2", nil)
	if err != nil || res == nil || !res.OK {
		t.Fatalf("second send failed after restart: %v", err)
	}
	if d2Received.Load() != 1 {
		t.Fatalf("expected 1 turn on daemon 2, got %d", d2Received.Load())
	}

	// Shared connection must now reflect daemon 2's port and token
	if conn.BaseURL() != fmt.Sprintf("http://127.0.0.1:%d", port2) {
		t.Fatalf("expected conn to have port %d, got %s", port2, conn.BaseURL())
	}
	if conn.AuthToken() != "token-2" {
		t.Fatalf("expected conn to have token-2, got %s", conn.AuthToken())
	}
}
