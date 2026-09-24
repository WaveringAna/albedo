package main

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/mattn/go-isatty"
)

var buildRoot string // Embedded at build time via -ldflags "-X main.buildRoot=..."

func isAlbedoRoot(dir string) bool {
	if dir == "" {
		return false
	}
	if _, err := os.Stat(filepath.Join(dir, "gleam.toml")); err == nil {
		if _, err := os.Stat(filepath.Join(dir, "src", "albedo.gleam")); err == nil {
			return true
		}
	}
	return false
}

func findProjectRoot() string {
	if env := os.Getenv("ALBEDO_ROOT"); env != "" && isAlbedoRoot(env) {
		return env
	}
	if exe, err := os.Executable(); err == nil {
		if resolved, err := filepath.EvalSymlinks(exe); err == nil {
			exe = resolved
		}
		// Check exe/../.. (e.g. repo/cli/bin/albedo -> repo)
		parent2 := filepath.Dir(filepath.Dir(exe))
		if isAlbedoRoot(parent2) {
			return parent2
		}
		parent3 := filepath.Dir(parent2)
		if isAlbedoRoot(parent3) {
			return parent3
		}
	}
	if buildRoot != "" && isAlbedoRoot(buildRoot) {
		return buildRoot
	}
	if cwd, err := os.Getwd(); err == nil {
		cur := cwd
		for {
			if isAlbedoRoot(cur) {
				return cur
			}
			parent := filepath.Dir(cur)
			if parent == cur {
				break
			}
			cur = parent
		}
	}
	if buildRoot != "" {
		return buildRoot
	}
	cwd, _ := os.Getwd()
	return cwd
}

func isTTY() bool {
	return isatty.IsTerminal(os.Stdin.Fd()) && isatty.IsTerminal(os.Stdout.Fd())
}

const helpText = `Usage: albedo [options] [command]

persistent coding sessions

Options:
  -h, --help                display help for command

Commands:
  new [workspace]           start a fresh session in the given workspace (defaults to current directory)
  resume <session>          resume a session by id or prefix
  sessions [options]        list active sessions
  send <session> <prompt>   send a prompt turn to a session
  stop <session>            interrupt an active session
  daemon [options]          inspect or manage daemon lifecycle
  login [name]              configure an API provider in terminal
`

func open(id, workspace string, fresh bool) error {
	ctx := context.Background()
	homeDir := config.HomeDir()
	projectRoot := findProjectRoot()

	absWorkspace, err := filepath.Abs(workspace)
	if err != nil {
		absWorkspace = workspace
	}

	conn, err := daemon.Ensure(homeDir, projectRoot)
	if err != nil {
		return err
	}

	sessions, err := daemon.Request[[]daemon.Session](ctx, conn, "/sessions", nil)
	if err != nil {
		return err
	}

	var selected *daemon.Session
	if id != "" {
		var matches []daemon.Session
		for _, s := range sessions {
			if s.ID == id || strings.HasPrefix(s.ID, id) {
				matches = append(matches, s)
			}
		}
		hasExact := false
		for _, s := range matches {
			if s.ID == id {
				hasExact = true
				break
			}
		}
		if len(matches) > 1 && !hasExact {
			return errors.New("session prefix is ambiguous")
		}
		if len(matches) == 0 {
			return errors.New("session not found")
		}
		for _, s := range matches {
			if s.ID == id {
				session := s
				selected = &session
				break
			}
		}
		if selected == nil && len(matches) > 0 {
			session := matches[0]
			selected = &session
		}
	}

	profs, err := config.LoadProfiles(homeDir)
	if err != nil {
		return err
	}
	configured := profs.Active != ""

	if !configured && !isTTY() {
		return errors.New("run albedo login in a terminal to save a provider")
	}

	var initial *daemon.Session
	if selected != nil {
		initial = selected
	} else if configured && (fresh || len(sessions) == 0) {
		created, err := daemon.Request[daemon.Session](ctx, conn, "/sessions", map[string]string{"workspace": absWorkspace})
		if err != nil {
			return err
		}
		initial = &created
	}

	if !isTTY() {
		type NonTTYOutput struct {
			Session  *string          `json:"session,omitempty"`
			Sessions []daemon.Session `json:"sessions"`
		}
		var sessID *string
		if initial != nil {
			sessID = &initial.ID
		}
		if sessions == nil {
			sessions = []daemon.Session{}
		}
		out := NonTTYOutput{
			Session:  sessID,
			Sessions: sessions,
		}
		data, err := json.Marshal(out)
		if err != nil {
			return err
		}
		fmt.Println(string(data))
		return nil
	}

	appModel := tui.NewAppModel(conn, profs, initial, absWorkspace, !configured)
	appModel.SessionPicker.LoadPrefs(filepath.Join(config.HomeDir(), "picker.json"))
	if os.Getenv("ALBEDO_NO_BROWSER") == "" {
		appModel.BrowserOpener = config.OpenBrowser
		appModel.Login.BrowserOpener = config.OpenBrowser
	}
	p := tea.NewProgram(appModel, tea.WithFPS(120))
	_, err = p.Run()
	return err
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	cwd, err := os.Getwd()
	if err != nil {
		cwd = "."
	}

	if len(args) == 0 {
		return open("", cwd, false)
	}

	cmd := args[0]
	subArgs := args[1:]

	switch cmd {
	case "-h", "--help", "help":
		fmt.Print(helpText)
		return nil

	case "new":
		workspace := cwd
		for i := 0; i < len(subArgs); i++ {
			if subArgs[i] == "-h" || subArgs[i] == "--help" {
				fmt.Println("Usage: albedo new [workspace]")
				return nil
			}
			if !strings.HasPrefix(subArgs[i], "-") {
				workspace = subArgs[i]
				break
			}
		}
		return open("", workspace, true)

	case "resume":
		if len(subArgs) == 0 || subArgs[0] == "-h" || subArgs[0] == "--help" {
			if len(subArgs) > 0 && (subArgs[0] == "-h" || subArgs[0] == "--help") {
				fmt.Println("Usage: albedo resume <session>")
				return nil
			}
			return errors.New("resume requires <session> argument")
		}
		return open(subArgs[0], cwd, false)

	case "sessions":
		asJSON := false
		for _, a := range subArgs {
			if a == "-h" || a == "--help" {
				fmt.Println("Usage: albedo sessions [--json]")
				return nil
			}
			if a == "--json" {
				asJSON = true
			}
		}
		homeDir := config.HomeDir()
		projectRoot := findProjectRoot()
		conn, err := daemon.Ensure(homeDir, projectRoot)
		if err != nil {
			return err
		}
		sessions, err := daemon.Request[[]daemon.Session](context.Background(), conn, "/sessions", nil)
		if err != nil {
			return err
		}
		if asJSON {
			data, err := json.MarshalIndent(sessions, "", "  ")
			if err != nil {
				return err
			}
			fmt.Println(string(data))
		} else {
			fmt.Println(daemon.SessionListing(sessions, time.Now()))
		}
		return nil

	case "send":
		if len(subArgs) > 0 && (subArgs[0] == "-h" || subArgs[0] == "--help") {
			fmt.Println("Usage: albedo send <session> <prompt>")
			return nil
		}
		if len(subArgs) < 2 {
			return errors.New("send requires <session> and <prompt> arguments")
		}
		sessID := subArgs[0]
		prompt := subArgs[1]
		homeDir := config.HomeDir()
		projectRoot := findProjectRoot()
		conn, err := daemon.Ensure(homeDir, projectRoot)
		if err != nil {
			return err
		}
		path := fmt.Sprintf("/sessions/%s/events", url.PathEscape(sessID))
		res, err := daemon.Request[any](context.Background(), conn, path, map[string]string{"content": prompt})
		if err != nil {
			return err
		}
		data, _ := json.Marshal(res)
		fmt.Println(string(data))
		return nil

	case "stop":
		if len(subArgs) > 0 && (subArgs[0] == "-h" || subArgs[0] == "--help") {
			fmt.Println("Usage: albedo stop <session>")
			return nil
		}
		if len(subArgs) < 1 {
			return errors.New("stop requires <session> argument")
		}
		sessID := subArgs[0]
		homeDir := config.HomeDir()
		projectRoot := findProjectRoot()
		conn, err := daemon.Ensure(homeDir, projectRoot)
		if err != nil {
			return err
		}
		path := fmt.Sprintf("/sessions/%s/interrupt", url.PathEscape(sessID))
		res, err := daemon.Request[any](context.Background(), conn, path, map[string]any{})
		if err != nil {
			return err
		}
		data, _ := json.Marshal(res)
		fmt.Println(string(data))
		return nil

	case "daemon":
		stop := false
		for _, a := range subArgs {
			if a == "-h" || a == "--help" {
				fmt.Println("Usage: albedo daemon [--stop]")
				return nil
			}
			if a == "--stop" {
				stop = true
			}
		}
		homeDir := config.HomeDir()
		if stop {
			current, err := daemon.Existing(homeDir)
			if err != nil {
				return err
			}
			if current != nil {
				_, err = daemon.Request[any](context.Background(), current, "/shutdown", map[string]any{})
				return err
			}
			return nil
		}
		projectRoot := findProjectRoot()
		current, err := daemon.Ensure(homeDir, projectRoot)
		if err != nil {
			return err
		}
		fmt.Printf("albedo daemon running on 127.0.0.1:%d\n", current.Port)
		return nil

	case "login":
		if len(subArgs) > 0 && (subArgs[0] == "-h" || subArgs[0] == "--help") {
			fmt.Println("Usage: albedo login [name]")
			return nil
		}
		if !isTTY() {
			return errors.New("login requires a terminal; keys are entered with hidden input")
		}
		providerName := ""
		if len(subArgs) > 0 {
			providerName = subArgs[0]
		}
		homeDir := config.HomeDir()
		projectRoot := findProjectRoot()
		conn, err := daemon.Ensure(homeDir, projectRoot)
		if err != nil {
			return err
		}
		profs, err := config.LoadProfiles(homeDir)
		if err != nil {
			return err
		}
		appModel := tui.NewAppModel(conn, profs, nil, cwd, true)
		appModel.StandaloneLogin = true
		if os.Getenv("ALBEDO_NO_BROWSER") == "" {
			appModel.BrowserOpener = config.OpenBrowser
			appModel.Login.BrowserOpener = config.OpenBrowser
		}
		if providerName != "" {
			appModel.Login = tui.NewLoginModel(conn, providerName)
			if os.Getenv("ALBEDO_NO_BROWSER") == "" {
				appModel.Login.BrowserOpener = config.OpenBrowser
			}
		}
		p := tea.NewProgram(appModel, tea.WithFPS(120))
		_, err = p.Run()
		return err

	default:
		return fmt.Errorf("unknown command %q", cmd)
	}
}
