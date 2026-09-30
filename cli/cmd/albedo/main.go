package main

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui"
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
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

// replaceStale asks before stopping a daemon from another build. Without a
// terminal it keeps the running daemon.
func replaceStale(s daemon.Stale) bool {
	if !isTTY() {
		fmt.Fprintf(os.Stderr, "Albedo is already running (PID %d). Keeping that copy because there is no terminal to ask about restarting.\nStopping Albedo will interrupt work in all sessions.\nWhen you are ready to use the copy you just launched, run albedo daemon --stop, then launch Albedo again.\n", s.Running.Pid())
		return false
	}
	fmt.Printf("Albedo is already running (PID %d). To use the copy you just launched,\nit needs to restart. This will interrupt work in all sessions.\n\nRestart Albedo? [y/N] ", s.Running.Pid())
	answer, _ := bufio.NewReader(os.Stdin).ReadString('\n')
	return confirmed(answer)
}

// announceMigration tells the user, once, that the daemon's start moved their
// secrets into creds.json, and waits for enter so the TUI does not cover it.
// The daemon answers only the first client that asks.
func announceMigration(ctx context.Context, conn *daemon.Connection, homeDir string) {
	moved, err := daemon.TakeMigration(ctx, conn)
	if err != nil || len(moved) == 0 {
		return
	}
	backups := filepath.Join(homeDir, "backups", "*-before-creds-*")
	fmt.Printf("Your credentials have been moved from %s to %s.\n", strings.Join(moved, ", "), filepath.Join(homeDir, "creds.json"))
	fmt.Printf("The backups still contain your credentials. Once you have checked that login works,\nyou can delete those backups with:\n\n  rm -f %s\n\nPress Enter to continue. ", backups)
	_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
}

// confirmed reads a [y/N] answer. A late reply to the terminal's startup
// queries can precede it.
func confirmed(answer string) bool {
	switch strings.ToLower(strings.TrimSpace(ansi.Strip(answer))) {
	case "y", "yes":
		return true
	}
	return false
}

const helpText = `Usage: albedo [options] [command]

persistent coding sessions

Options:
  -h, --help                show help

Commands:
  new [workspace]           start a fresh session in the given workspace (defaults to current directory)
  resume <session>          reopen a session using its ID or the start of its ID
  sessions [options]        list sessions
  send <session> <prompt>   send a message to a session
  stop <session>            interrupt work in a session
  daemon [options]          start Albedo in the background, or stop it with --stop
  storage [options]         show disk usage or clean up selected data
  login [name]              set up a model provider in a terminal
`

func open(id, workspace string, fresh bool, openBrowser func(string)) error {
	ctx := context.Background()
	homeDir := config.HomeDir()
	projectRoot := findProjectRoot()

	absWorkspace, err := filepath.Abs(workspace)
	if err != nil {
		absWorkspace = workspace
	}

	conn, err := daemon.Ensure(homeDir, projectRoot, replaceStale)
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
			return fmt.Errorf("More than one session ID starts with %q. Use a longer ID or run albedo sessions to find it.", id)
		}
		if len(matches) == 0 {
			return fmt.Errorf("No session matches %q. Run albedo sessions to see the available sessions.", id)
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

	profs, err := daemon.ProviderProfiles(ctx, conn)
	if err != nil {
		return err
	}
	configured := profs.Active != ""

	if !configured && !isTTY() {
		return errors.New("No model provider is configured. Run albedo login in a terminal to set one up.")
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

	announceMigration(ctx, conn, homeDir)
	tui.DetectInk()
	appModel := tui.NewAppModel(conn, profs, initial, absWorkspace, !configured, openBrowser)
	p := tea.NewProgram(appModel, tea.WithFPS(120))
	final, err := p.Run()
	if err != nil {
		return err
	}
	if m, ok := final.(tui.AppModel); ok && m.ActiveSession != nil {
		fmt.Printf("To reopen this session, run albedo resume %s\n", m.ActiveSession.ID)
	}
	return nil
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	var openBrowser func(string)
	if os.Getenv("ALBEDO_NO_BROWSER") == "" {
		openBrowser = config.OpenBrowser
	}

	cwd, err := os.Getwd()
	if err != nil {
		cwd = "."
	}

	if len(args) == 0 {
		return open("", cwd, false, openBrowser)
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
		return open("", workspace, true, openBrowser)

	case "resume":
		if len(subArgs) == 0 || subArgs[0] == "-h" || subArgs[0] == "--help" {
			if len(subArgs) > 0 && (subArgs[0] == "-h" || subArgs[0] == "--help") {
				fmt.Println("Usage: albedo resume <session>")
				return nil
			}
			return errors.New("Choose a session to reopen: albedo resume <session>")
		}
		return open(subArgs[0], cwd, false, openBrowser)

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
		conn, err := daemon.Ensure(homeDir, projectRoot, replaceStale)
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
			return errors.New("Choose a session and a message to send: albedo send <session> <prompt>")
		}
		sessID := subArgs[0]
		prompt := subArgs[1]
		homeDir := config.HomeDir()
		projectRoot := findProjectRoot()
		conn, err := daemon.Ensure(homeDir, projectRoot, replaceStale)
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
			return errors.New("Choose a session to interrupt: albedo stop <session>")
		}
		sessID := subArgs[0]
		homeDir := config.HomeDir()
		projectRoot := findProjectRoot()
		conn, err := daemon.Ensure(homeDir, projectRoot, replaceStale)
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

	case "storage":
		return storageCommand(subArgs)

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
		current, err := daemon.Ensure(homeDir, projectRoot, replaceStale)
		if err != nil {
			return err
		}
		fmt.Printf("Albedo is running in the background at 127.0.0.1:%d\n", current.Port())
		return nil

	case "login":
		if len(subArgs) > 0 && (subArgs[0] == "-h" || subArgs[0] == "--help") {
			fmt.Println("Usage: albedo login [name]")
			return nil
		}
		if !isTTY() {
			return errors.New("Run albedo login in a terminal so you can enter your API key without displaying it.")
		}
		providerName := ""
		if len(subArgs) > 0 {
			providerName = subArgs[0]
		}
		homeDir := config.HomeDir()
		projectRoot := findProjectRoot()
		conn, err := daemon.Ensure(homeDir, projectRoot, replaceStale)
		if err != nil {
			return err
		}
		profs, err := daemon.ProviderProfiles(context.Background(), conn)
		if err != nil {
			return err
		}
		announceMigration(context.Background(), conn, homeDir)
		tui.DetectInk()
		appModel := tui.NewLoginAppModel(conn, profs, cwd, providerName, openBrowser)
		p := tea.NewProgram(appModel, tea.WithFPS(120))
		_, err = p.Run()
		return err

	default:
		return fmt.Errorf("Unknown command %q. Run albedo --help to see the available commands.", cmd)
	}
}
