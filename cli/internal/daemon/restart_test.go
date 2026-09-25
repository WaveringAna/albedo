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
	"time"
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

// TestChatClientStreamReconnectsAfterDaemonRestart verifies that when a daemon restarts,
// Stream() discovers the new daemon and connects to it.
func TestChatClientStreamReconnectsAfterDaemonRestart(t *testing.T) {
	tempDir := t.TempDir()

	d1 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"ok":true,"version":2}`))
			return
		}
		// Immediately close or reject stream to simulate restart
		w.WriteHeader(http.StatusServiceUnavailable)
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

	// Daemon 1 shuts down immediately
	d1.Close()

	// Daemon 2 starts
	d2StreamConnected := make(chan struct{})
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
		if strings.HasPrefix(r.URL.Path, "/sessions/sess-1/stream") {
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("event: reset\ndata: {}\n\n"))
			if f, ok := w.(http.Flusher); ok {
				f.Flush()
			}
			close(d2StreamConnected)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer d2.Close()

	port2 := parsePort(d2.URL)
	writeDaemonRecord(t, tempDir, port2, "token-2")

	// When Stream is called, it should connect to daemon 2
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	var gotReset atomic.Bool
	go func() {
		_ = client.Stream(ctx, nil, func(ev StreamEvent) error {
			if ev.Type == EventReset {
				gotReset.Store(true)
			}
			return nil
		})
	}()

	select {
	case <-d2StreamConnected:
		// Succeeded connecting to daemon 2!
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for stream to connect to restarted daemon")
	}

	if conn.AuthToken() != "token-2" {
		t.Fatalf("expected conn token-2, got %s", conn.AuthToken())
	}
}

// TestRequestMethodReconnectsAfterDaemonRestart verifies that Request[T] / RequestMethod
// transparently reconnects when the daemon restarts.
func TestRequestMethodReconnectsAfterDaemonRestart(t *testing.T) {
	tempDir := t.TempDir()

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
		if r.URL.Path == "/sessions" {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`[{"id":"s1","workspace":"/w"}]`))
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	port1 := parsePort(d1.URL)
	writeDaemonRecord(t, tempDir, port1, "token-1")

	conn, err := Existing(tempDir)
	if err != nil || conn == nil {
		t.Fatalf("failed to get conn: %v", err)
	}

	sessions, err := Request[[]Session](context.Background(), conn, "/sessions", nil)
	if err != nil || len(sessions) != 1 {
		t.Fatalf("initial request failed: %v", err)
	}

	// Shut down d1
	d1.Close()

	// Start d2
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
		if r.URL.Path == "/sessions" {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`[{"id":"s1","workspace":"/w"},{"id":"s2","workspace":"/w2"}]`))
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer d2.Close()

	port2 := parsePort(d2.URL)
	writeDaemonRecord(t, tempDir, port2, "token-2")

	// Call Request again; should auto-reconnect to d2
	sessions2, err := Request[[]Session](context.Background(), conn, "/sessions", nil)
	if err != nil {
		t.Fatalf("request after restart failed: %v", err)
	}
	if len(sessions2) != 2 {
		t.Fatalf("expected 2 sessions from d2, got %d", len(sessions2))
	}
	if conn.AuthToken() != "token-2" {
		t.Fatalf("expected conn token-2, got %s", conn.AuthToken())
	}
}

// TestDaemonPermanentlyDownReturnsError verifies that if the daemon is stopped
// and never restarts, the client returns an error rather than hanging.
func TestDaemonPermanentlyDownReturnsError(t *testing.T) {
	tempDir := t.TempDir()

	// Write daemon record for a port where nothing is listening
	writeDaemonRecord(t, tempDir, 59999, "token-dead")

	conn := NewConnection(ConnectionSnapshot{
		Port:    59999,
		Token:   "token-dead",
		Version: 2,
	}, tempDir)

	client := NewChatClient(ChatClientOptions{
		AgentID: "sess-1",
		Conn:    conn,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	_, err := client.Send(ctx, "test", nil)
	if err == nil {
		t.Fatal("expected error when daemon is permanently dead")
	}
}
