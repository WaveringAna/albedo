package main

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestIsAlbedoRoot(t *testing.T) {
	tempDir := t.TempDir()
	if isAlbedoRoot(tempDir) {
		t.Errorf("empty dir should not be albedo root")
	}

	// Add gleam.toml only
	_ = os.WriteFile(filepath.Join(tempDir, "gleam.toml"), []byte(`name = "test"`), 0644)
	if isAlbedoRoot(tempDir) {
		t.Errorf("dir with only gleam.toml should not be albedo root")
	}

	// Add src/albedo.gleam
	_ = os.MkdirAll(filepath.Join(tempDir, "src"), 0755)
	_ = os.WriteFile(filepath.Join(tempDir, "src", "albedo.gleam"), []byte("// test"), 0644)
	if !isAlbedoRoot(tempDir) {
		t.Errorf("dir with gleam.toml and src/albedo.gleam must be recognized as albedo root")
	}
}

func TestFindProjectRoot_EnvOverride(t *testing.T) {
	tempDir := t.TempDir()
	_ = os.WriteFile(filepath.Join(tempDir, "gleam.toml"), []byte(`name = "test"`), 0644)
	_ = os.MkdirAll(filepath.Join(tempDir, "src"), 0755)
	_ = os.WriteFile(filepath.Join(tempDir, "src", "albedo.gleam"), []byte("// test"), 0644)

	t.Setenv("ALBEDO_ROOT", tempDir)
	root := findProjectRoot()
	if root != tempDir {
		t.Errorf("expected ALBEDO_ROOT=%s, got %s", tempDir, root)
	}
}

func TestRun_HelpCommands(t *testing.T) {
	for _, cmd := range [][]string{{"-h"}, {"--help"}, {"help"}} {
		err := run(cmd)
		if err != nil {
			t.Errorf("run(%v) failed: %v", cmd, err)
		}
	}

	for _, sub := range []string{"new", "resume", "sessions", "send", "stop", "daemon", "login"} {
		err := run([]string{sub, "--help"})
		if err != nil {
			t.Errorf("run([%s, --help]) failed: %v", sub, err)
		}
	}
}

func TestRun_UnknownCommand(t *testing.T) {
	err := run([]string{"nonexistent-subcommand"})
	if err == nil || !strings.Contains(err.Error(), "unknown command") {
		t.Errorf("expected unknown command error, got: %v", err)
	}
}

func TestRun_MissingArguments(t *testing.T) {
	if err := run([]string{"resume"}); err == nil || !strings.Contains(err.Error(), "resume requires") {
		t.Errorf("expected resume requires argument error, got: %v", err)
	}
	if err := run([]string{"send"}); err == nil || !strings.Contains(err.Error(), "send requires") {
		t.Errorf("expected send requires argument error, got: %v", err)
	}
	if err := run([]string{"send", "session1"}); err == nil || !strings.Contains(err.Error(), "send requires") {
		t.Errorf("expected send requires 2 args error, got: %v", err)
	}
	if err := run([]string{"stop"}); err == nil || !strings.Contains(err.Error(), "stop requires") {
		t.Errorf("expected stop requires argument error, got: %v", err)
	}
}

func TestRun_LoginNonTTYRejection(t *testing.T) {
	err := run([]string{"login"})
	if err == nil || !strings.Contains(err.Error(), "login requires a terminal") {
		t.Errorf("expected login non-TTY error, got: %v", err)
	}
}

func TestNonTTYSessionJSONOmitempty(t *testing.T) {
	type NonTTYOutput struct {
		Session  *string  `json:"session,omitempty"`
		Sessions []string `json:"sessions"`
	}

	// Without initial session: session key must be omitted
	out1 := NonTTYOutput{Session: nil, Sessions: []string{"s1"}}
	data1, _ := json.Marshal(out1)
	if strings.Contains(string(data1), `"session":`) {
		t.Errorf("expected session key omitted when nil, got: %s", string(data1))
	}

	// With initial session: session key must be present
	id := "abc12345"
	out2 := NonTTYOutput{Session: &id, Sessions: []string{"s1"}}
	data2, _ := json.Marshal(out2)
	if !strings.Contains(string(data2), `"session":"abc12345"`) {
		t.Errorf("expected session key present, got: %s", string(data2))
	}
}

func TestRun_SessionsWithMockDaemon(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("ALBEDO_HOME", homeDir)

	sessions := []map[string]any{
		{
			"id":        "deadbeef12345678",
			"title":     "Test Session",
			"workspace": "/tmp",
			"model":     "fixture",
			"protocol":  "responses",
			"provider":  "openai",
		},
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-token" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if r.URL.Path == "/health" {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "version": 2})
			return
		}
		if r.URL.Path == "/sessions" {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(sessions)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer server.Close()

	port := server.Listener.Addr().(*net.TCPAddr).Port
	daemonJSON := map[string]any{
		"port":    port,
		"token":   "test-token",
		"pid":     os.Getpid(),
		"version": 2,
	}
	data, _ := json.Marshal(daemonJSON)
	_ = os.WriteFile(filepath.Join(homeDir, "daemon.json"), data, 0600)

	// Test sessions --json
	err := run([]string{"sessions", "--json"})
	if err != nil {
		t.Fatalf("sessions --json failed: %v", err)
	}

	// Test sessions (plain text)
	err = run([]string{"sessions"})
	if err != nil {
		t.Fatalf("sessions plain failed: %v", err)
	}
}
