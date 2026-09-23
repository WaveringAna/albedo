package main

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui"
	"context"
	"errors"
	"flag"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

var visualCodexMode = flag.String("visual-codex", "", "run the isolated visual Codex PTY driver (success or error)")

func main() {
	flag.Parse()
	if *visualCodexMode == "" {
		panic("explicit --visual-codex=success|error required")
	}
	if *visualCodexMode != "success" && *visualCodexMode != "error" {
		panic("unknown fake exchange mode")
	}
	home := os.Getenv("ALBEDO_HOME")
	if os.Getenv("ALBEDO_NO_BROWSER") != "1" || !strings.Contains(home, "albedo-visual-home-") {
		panic("fake driver requires an isolated visual home and disabled browser")
	}
	conn, err := daemon.Existing(home)
	if err != nil || conn == nil {
		panic("isolated fixture daemon not available")
	}
	m := tui.NewAppModel(conn, config.Profiles{}, nil, "/tmp/albedo-visual-fixture", true)
	m.StandaloneLogin = true
	m.Login = tui.NewLoginModel(conn, "codex")
	m.BrowserOpener = func(url string) { _ = os.WriteFile(filepath.Join(home, "browser-blocked.log"), []byte(url+"\n"), 0600) }
	m.Login.BrowserOpener = m.BrowserOpener
	m.Login.ExchangeCodeFunc = func(ctx context.Context, client *http.Client, code, verifier string) (*config.CodexCredential, error) {
		if code != "fixture-code" || verifier == "" {
			return nil, errors.New("fake authorization code required")
		}
		if *visualCodexMode == "error" {
			return nil, errors.New("fixture authorization rejected")
		}
		return &config.CodexCredential{Type: "oauth", AccountID: "fixture-account", Access: "fixture-access", Refresh: "fixture-refresh", Expires: 4102444800000}, nil
	}
	if _, err := tea.NewProgram(m, tea.WithInput(os.Stdin), tea.WithOutput(os.Stdout)).Run(); err != nil {
		panic(err)
	}
}
