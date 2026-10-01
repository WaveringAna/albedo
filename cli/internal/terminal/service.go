// Package terminal owns interactive confirmation, notices, and Bubble Tea launch.
package terminal

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"albedo/cli/internal/app"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/mattn/go-isatty"
)

type Service struct {
	In          io.Reader
	Out, Err    io.Writer
	OpenBrowser func(string)
	Home        string
	Capable     bool
}

func IsTTY(in io.Reader, out io.Writer) bool {
	input, inputOK := in.(*os.File)
	output, outputOK := out.(*os.File)
	return inputOK && outputOK && isatty.IsTerminal(input.Fd()) && isatty.IsTerminal(output.Fd())
}

// ReplaceStale asks before stopping a daemon from another build. Without a
// terminal it keeps the running daemon.
func (t *Service) ReplaceStale(s daemon.Stale) bool {
	if !t.Capable {
		fmt.Fprintf(t.Err, "Albedo is already running (PID %d). Keeping that copy because there is no terminal to ask about restarting.\nStopping Albedo will interrupt work in all sessions.\nWhen you are ready to use the copy you just launched, run albedo daemon --stop, then launch Albedo again.\n", s.Running.Pid())
		return false
	}
	if _, err := fmt.Fprintf(t.Out, "Albedo is already running (PID %d). To use the copy you just launched,\nit needs to restart. This will interrupt work in all sessions.\n\nRestart Albedo? [y/N] ", s.Running.Pid()); err != nil {
		return false
	}
	answer, _ := bufio.NewReader(t.In).ReadString('\n')
	return Confirmed(answer)
}

// announceMigration tells the user, once, that the daemon's start moved their
// secrets into creds.json, and waits for enter so the TUI does not cover it.
// The daemon answers only the first client that asks.
func (t *Service) announceMigration(ctx context.Context, conn *daemon.Connection) error {
	moved, err := daemon.TakeMigration(ctx, conn)
	if err != nil || len(moved) == 0 {
		return nil
	}
	backups := filepath.Join(t.Home, "backups", "*-before-creds-*")
	if _, writeErr := fmt.Fprintf(t.Out, "Your credentials have been moved from %s to %s.\n", strings.Join(moved, ", "), filepath.Join(t.Home, "creds.json")); writeErr != nil {
		return writeErr
	}
	if _, writeErr := fmt.Fprintf(t.Out, "The backups still contain your credentials. Once you have checked that login works,\nyou can delete those backups with:\n\n  rm -f %s\n\nPress Enter to continue. ", backups); writeErr != nil {
		return writeErr
	}
	_, err = bufio.NewReader(t.In).ReadString('\n')
	if errors.Is(err, io.EOF) {
		return nil
	}
	return err
}

// Confirmed reads a [y/N] answer. A late reply to the terminal's startup
// queries can precede it.
func Confirmed(answer string) bool {
	switch strings.ToLower(strings.TrimSpace(ansi.Strip(answer))) {
	case "y", "yes":
		return true
	}
	return false
}

func (t *Service) Open(ctx context.Context, prepared app.PreparedOpen) error {
	if err := t.announceMigration(ctx, prepared.Connection); err != nil {
		return err
	}
	tui.DetectInk()
	appModel := tui.NewAppModel(prepared.Connection, prepared.Providers, prepared.Selected, prepared.Workspace, prepared.LoginRequired, t.OpenBrowser)
	p := tea.NewProgram(appModel, tea.WithFPS(120), tea.WithInput(t.In), tea.WithOutput(t.Out))
	final, err := p.Run()
	if err != nil {
		return err
	}
	if m, ok := final.(tui.AppModel); ok && m.ActiveSession != nil {
		_, err = fmt.Fprintf(t.Out, "To reopen this session, run albedo resume %s\n", m.ActiveSession.ID)
	}
	return err
}

func (t *Service) Login(ctx context.Context, prepared app.PreparedOpen, workspace, name string) error {
	if err := t.announceMigration(ctx, prepared.Connection); err != nil {
		return err
	}
	tui.DetectInk()
	model := tui.NewLoginAppModel(prepared.Connection, prepared.Providers, workspace, name, t.OpenBrowser)
	_, err := tea.NewProgram(model, tea.WithFPS(120), tea.WithInput(t.In), tea.WithOutput(t.Out)).Run()
	return err
}
func (t *Service) ConfirmCleanup(sessions bool) (bool, error) {
	if !t.Capable {
		return false, errors.New("no files have been removed; run cleanup in a terminal to confirm, or add --yes to approve the changes shown above")
	}
	prompt := "Apply the cleanup shown above? [y/N] "
	if sessions {
		prompt = "Permanently delete the sessions listed above? [y/N] "
	}
	if _, err := fmt.Fprint(t.Out, prompt); err != nil {
		return false, err
	}
	answer, err := bufio.NewReader(t.In).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return false, err
	}
	return Confirmed(answer), nil
}
