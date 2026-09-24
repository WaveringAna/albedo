package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
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
	env := strings.Join(buildDaemonEnv("/tmp/home", "token", ""), "\n")
	if strings.Contains(env, "do-not-inherit") || !strings.Contains(env, "ALBEDO_HOME=/tmp/home") || !strings.Contains(env, "ALBEDO_TOKEN=token") {
		t.Fatal("incorrect daemon environment")
	}
}

func TestDaemonEnvironmentKeepsOperatorErlFlagsLast(t *testing.T) {
	t.Setenv("ERL_FLAGS", "+P 500000")
	env := buildDaemonEnv("/tmp/home", "token", "")
	var flags []string
	for _, kv := range env {
		if strings.HasPrefix(kv, "ERL_FLAGS=") {
			flags = append(flags, kv)
		}
	}
	if len(flags) != 1 || flags[0] != "ERL_FLAGS="+daemonErlFlags+" +P 500000" {
		t.Fatalf("ERL_FLAGS = %q", flags)
	}
}

func TestDaemonEnvironmentCarriesOnlyTheLaunchedBuild(t *testing.T) {
	t.Setenv("ALBEDO_BUILD", "/nix/store/inherited")
	env := strings.Join(buildDaemonEnv("/tmp/home", "token", "/nix/store/new/bin/daemon"), "\n")
	if strings.Contains(env, "inherited") || !strings.Contains(env, "ALBEDO_BUILD=/nix/store/new/bin/daemon") {
		t.Fatalf("incorrect build in environment:\n%s", env)
	}
	if strings.Contains(strings.Join(buildDaemonEnv("/tmp/home", "token", ""), "\n"), "ALBEDO_BUILD") {
		t.Fatal("a source daemon was given a build")
	}
}

// fakeDaemon serves /health until /shutdown and records a daemon.json for it.
func fakeDaemon(t *testing.T, build string, pid int) (home string, down *atomic.Bool) {
	t.Helper()
	down = new(atomic.Bool)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/shutdown":
			down.Store(true)
			_, _ = w.Write([]byte(`{"ok":true}`))
		case r.URL.Path == "/health" && !down.Load():
			_, _ = w.Write([]byte(`{"ok":true,"version":2}`))
		default:
			w.WriteHeader(http.StatusServiceUnavailable)
		}
	}))
	t.Cleanup(ts.Close)
	port, _ := strconv.Atoi(ts.URL[strings.LastIndex(ts.URL, ":")+1:])
	home = t.TempDir()
	data, _ := json.Marshal(Connection{Port: port, Token: "t", Pid: pid, Version: 2, Build: build})
	if err := os.WriteFile(filepath.Join(home, "daemon.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	return home, down
}

func bundledDaemon(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "albedo-daemon")
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 1\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ALBEDO_DAEMON", path)
	return bundledBuild(path)
}

func TestEnsureAsksOnlyAboutAnotherBundledBuild(t *testing.T) {
	cases := []struct {
		name    string
		bundled bool
		running string // "" = no build recorded, "same" = the bundled build
		asked   bool
	}{
		{"source client", false, "/nix/store/old", false},
		{"same build", true, "same", false},
		{"other build", true, "/nix/store/old", true},
		{"unrecorded build", true, "", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Setenv("ALBEDO_DAEMON", "")
			build := ""
			if c.bundled {
				build = bundledDaemon(t)
			}
			running := c.running
			if running == "same" {
				running = build
			}
			home, down := fakeDaemon(t, running, os.Getpid())
			var asked []Stale
			conn, err := Ensure(home, "unused", func(s Stale) bool { asked = append(asked, s); return false })
			if err != nil || conn == nil || down.Load() {
				t.Fatalf("declined replacement changed the daemon: conn=%v err=%v down=%v", conn, err, down.Load())
			}
			if (len(asked) == 1) != c.asked {
				t.Fatalf("asked %d times, want asked=%v", len(asked), c.asked)
			}
			if c.asked && (asked[0].Bundled != build || asked[0].Running.Build != running) {
				t.Fatalf("unexpected stale report: %+v", asked[0])
			}
		})
	}
}

func TestStopWaitsForShutdown(t *testing.T) {
	exited := exec.Command("true")
	if err := exited.Run(); err != nil {
		t.Fatal(err)
	}
	home, down := fakeDaemon(t, "", exited.Process.Pid)
	conn, err := Existing(home)
	if err != nil || conn == nil {
		t.Fatalf("fake daemon not found: %v", err)
	}
	if err := stop(home, conn); err != nil || !down.Load() {
		t.Fatalf("stop: err=%v down=%v", err, down.Load())
	}
}
