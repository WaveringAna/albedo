// Daemon startup must not leak inherited API secrets, and bundled-build replacement prompts must not interrupt source clients.
package daemon

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
)

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
	data, _ := json.Marshal(ConnectionSnapshot{Port: port, Token: "t", Pid: pid, Version: 2, Build: build})
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
			if c.asked && (asked[0].Bundled != build || asked[0].Running.Build() != running) {
				t.Fatalf("unexpected stale report: %+v", asked[0])
			}
		})
	}
}
