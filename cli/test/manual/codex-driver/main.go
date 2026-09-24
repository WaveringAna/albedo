// Manual driver for the isolated visual Codex PTY captures. The daemon owns the
// sign-in now, so this driver stands in for one: it serves the sign-in routes
// and runs the same /login screens the shipped client shows, with no browser,
// no provider, and no real credential.
package main

import (
	"encoding/json"
	"flag"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui"

	tea "github.com/charmbracelet/bubbletea"
)

var visualCodexMode = flag.String("visual-codex", "", "run the isolated visual Codex PTY driver (success or error)")

const (
	driverToken  = "visual-codex-driver"
	driverSignIn = "driver-signin"
)

// fixture is the stand-in daemon: the real sign-in routes, with the exchange
// already decided by the requested mode.
type fixture struct {
	mode    string
	status  daemon.SignInStatus
	written bool
}

func (f *fixture) serve(w http.ResponseWriter, r *http.Request) {
	reply := func(status int, value any) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(value)
	}
	if r.Header.Get("Authorization") != "Bearer "+driverToken {
		reply(http.StatusForbidden, map[string]string{"error": "forbidden"})
		return
	}

	path := r.URL.Path
	switch {
	case r.Method == http.MethodGet && path == "/health":
		reply(http.StatusOK, map[string]any{"ok": true, "version": 2})
	case r.Method == http.MethodGet && path == "/auth":
		accounts := []daemon.Account{}
		if f.mode == "success" && f.written {
			accounts = append(accounts, daemon.Account{
				Provider: "codex",
				ID:       "account:driver",
				Label:    "fixture@example.test · plus",
				Detail:   "chatgpt account · selected",
				Selected: true,
			})
		}
		reply(http.StatusOK, daemon.SignIns{
			Logins: []daemon.SignIn{{
				Provider: "codex",
				Label:    "add chatgpt codex account",
				Detail:   "oauth · supports multiple accounts",
				Protocol: "responses",
			}},
			Accounts: accounts,
		})
	case r.Method == http.MethodPost && path == "/auth/codex":
		reply(http.StatusCreated, daemon.StartedSignIn{ID: driverSignIn, URL: "https://auth.openai.com/oauth/authorize?driver=fixture"})
	case r.Method == http.MethodGet && path == "/auth/logins/"+driverSignIn:
		reply(http.StatusOK, f.status)
	case r.Method == http.MethodPost && path == "/auth/logins/"+driverSignIn:
		f.written = true
		if f.mode == "error" {
			f.status = daemon.SignInStatus{State: "failed", Message: "fixture authorization rejected"}
		} else {
			f.status = daemon.SignInStatus{State: "done", Message: "fixture@example.test · plus"}
		}
		reply(http.StatusOK, map[string]bool{"ok": true})
	case r.Method == http.MethodDelete:
		reply(http.StatusOK, map[string]bool{"ok": true})
	case r.Method == http.MethodGet && strings.HasPrefix(path, "/models/"):
		reply(http.StatusOK, []string{"gpt-5", "gpt-5-mini", "codex-mini-latest"})
	default:
		reply(http.StatusNotFound, map[string]string{"error": "unhandled driver route " + r.Method + " " + path})
	}
}

func main() {
	flag.Parse()
	if *visualCodexMode != "success" && *visualCodexMode != "error" {
		panic("explicit --visual-codex=success|error required")
	}
	home := os.Getenv("ALBEDO_HOME")
	if os.Getenv("ALBEDO_NO_BROWSER") != "1" || !strings.Contains(home, "albedo-visual-home-") {
		panic("driver requires an isolated visual home and disabled browser")
	}

	f := &fixture{mode: *visualCodexMode, status: daemon.SignInStatus{State: "waiting", Message: "waiting for browser authorization"}}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	go func() { _ = http.Serve(listener, http.HandlerFunc(f.serve)) }()
	record, err := json.Marshal(daemon.Connection{
		Port:    listener.Addr().(*net.TCPAddr).Port,
		Token:   driverToken,
		Pid:     os.Getpid(),
		Version: 2,
	})
	if err != nil {
		panic(err)
	}
	if err := os.WriteFile(filepath.Join(home, "daemon.json"), record, 0600); err != nil {
		panic(err)
	}
	conn, err := daemon.Existing(home)
	if err != nil || conn == nil {
		panic("driver daemon not available")
	}

	profiles, err := config.LoadProfiles(home)
	if err != nil {
		panic(err)
	}
	m := tui.NewAppModel(conn, profiles, nil, "/tmp/albedo-visual-fixture", true)
	m.StandaloneLogin = true
	m.Login = tui.NewLoginModel(conn, "codex")
	m.BrowserOpener = func(url string) { _ = os.WriteFile(filepath.Join(home, "browser-blocked.log"), []byte(url+"\n"), 0600) }
	m.Login.BrowserOpener = m.BrowserOpener
	if _, err := tea.NewProgram(m, tea.WithInput(os.Stdin), tea.WithOutput(os.Stdout)).Run(); err != nil {
		panic(err)
	}
}
