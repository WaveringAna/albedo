package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestExistingAndRequest(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		if auth != "Bearer test-token" {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":"unauthorized"}`))
			return
		}

		if r.URL.Path == "/health" {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"ok":true,"version":2}`))
			return
		}

		if r.URL.Path == "/test" {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"status":"success"}`))
			return
		}

		w.WriteHeader(http.StatusNotFound)
	}))
	defer ts.Close()

	parts := strings.Split(ts.URL, ":")
	portStr := parts[len(parts)-1]
	port, _ := strconv.Atoi(portStr)

	tempDir, err := os.MkdirTemp("", "albedo-lifecycle-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tempDir)

	connInfo := Connection{
		Port:    port,
		Token:   "test-token",
		Pid:     1234,
		Version: 2,
	}
	data, _ := json.Marshal(connInfo)
	_ = os.WriteFile(filepath.Join(tempDir, "daemon.json"), data, 0600)

	conn, err := Existing(tempDir)
	if err != nil {
		t.Fatal(err)
	}
	if conn == nil {
		t.Fatal("expected active connection from Existing()")
	}
	if conn.Port != port || conn.Token != "test-token" {
		t.Fatalf("unexpected conn info: %+v", conn)
	}

	type TestResp struct {
		Status string `json:"status"`
	}
	resp, err := Request[TestResp](context.Background(), conn, "/test", nil)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	if resp.Status != "success" {
		t.Fatalf("expected success, got %s", resp.Status)
	}
}

func TestCheckCompatibleVersion(t *testing.T) {
	conn1 := &Connection{Version: 1}
	if _, err := checkCompatible(conn1); err == nil {
		t.Fatal("expected error on version 1 daemon")
	}

	conn2 := &Connection{Version: 2}
	if _, err := checkCompatible(conn2); err != nil {
		t.Fatalf("expected nil error on version 2 daemon, got: %v", err)
	}
}

func TestPackagedDaemonCommand(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon with spaces")
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
		t.Fatal(err)
	}
	env := []string{"ALBEDO_HOME=/tmp/fixture", "ALBEDO_TOKEN=fixture"}
	cmd, err := daemonCommand(path, "/missing/source/tree", env)
	if err != nil {
		t.Fatal(err)
	}
	if cmd.Path != path || len(cmd.Args) != 1 || cmd.Args[0] != path || cmd.Dir != "" {
		t.Fatalf("unexpected packaged command: %#v", cmd)
	}
	if strings.Join(cmd.Env, "\n") != strings.Join(env, "\n") {
		t.Fatal("environment changed")
	}
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
}

func TestDaemonOverrideValidation(t *testing.T) {
	dir := t.TempDir()
	nonExecutable := filepath.Join(dir, "not-executable")
	if err := os.WriteFile(nonExecutable, nil, 0600); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"relative-daemon", dir, nonExecutable, filepath.Join(dir, "missing")} {
		if _, err := daemonCommand(path, "unused", nil); err == nil {
			t.Errorf("accepted invalid daemon %q", path)
		}
	}
}

func TestDevelopmentDaemonCommand(t *testing.T) {
	cmd, err := daemonCommand("", "/source/albedo", []string{"fixture=value"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(cmd.Args, " ") != "gleam run" || cmd.Dir != "/source/albedo" {
		t.Fatalf("unexpected development command: %#v", cmd)
	}
}

func TestDaemonEnvironment(t *testing.T) {
	for _, key := range []string{"ALBEDO_API_KEY", "ALBEDO_MODEL", "ALBEDO_BASE_URL", "ALBEDO_PROTOCOL"} {
		t.Setenv(key, "do-not-inherit")
	}
	t.Setenv("ALBEDO_DAEMON", "/nix/store/fixture/bin/daemon")
	env := strings.Join(buildDaemonEnv("/tmp/home", "token"), "\n")
	if strings.Contains(env, "do-not-inherit") || !strings.Contains(env, "ALBEDO_HOME=/tmp/home") || !strings.Contains(env, "ALBEDO_TOKEN=token") {
		t.Fatal("incorrect daemon environment")
	}
}
