// Package terminal owns interactive confirmation, notices, and Bubble Tea launch.
package terminal

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"runtime/debug"
	"slices"
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

// announceMigration presents retained daemon notices before the full screen opens.
func (t *Service) announceMigration(ctx context.Context, conn *daemon.Connection, settings daemon.Settings) (daemon.Settings, error) {
	server, err := daemon.ProbeServer(ctx, conn)
	if err != nil {
		return daemon.Settings{}, err
	}
	dismissed := slices.Clone(settings.UI.DismissedNotices)
	shown := false
	for _, notice := range server.Notices {
		if slices.Contains(dismissed, notice.ID) {
			continue
		}
		if _, err := fmt.Fprintln(t.Out, notice.Message); err != nil {
			return daemon.Settings{}, err
		}
		dismissed = append(dismissed, notice.ID)
		shown = true
	}
	if !shown {
		return settings, nil
	}
	if _, err := fmt.Fprint(t.Out, "Press Enter to continue. "); err != nil {
		return daemon.Settings{}, err
	}
	_, err = bufio.NewReader(t.In).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return daemon.Settings{}, err
	}
	if err := daemon.DismissServerNotices(ctx, conn, settings.UI.ETag, dismissed); err != nil {
		return daemon.Settings{}, err
	}
	// Acknowledgement changes the UI validator; seed the TUI from that result.
	return daemon.GetSettings(ctx, conn)
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
	settings, err := t.announceMigration(ctx, prepared.Connection, prepared.Settings)
	if err != nil {
		return err
	}
	if err := tui.DetectInk(); err != nil {
		return err
	}
	leanHeap()
	appModel := tui.NewAppModel(prepared.Connection, tui.Bootstrap{Sessions: prepared.Sessions, Settings: settings}, prepared.Selected, prepared.Workspace, prepared.LoginRequired, t.OpenBrowser)
	p := tea.NewProgram(appModel, tea.WithInput(t.In), tea.WithOutput(t.Out))
	stopCancellation := context.AfterFunc(ctx, func() { p.Send(tea.Quit()) })
	defer stopCancellation()
	final, err := p.Run()
	closed, ok := final.(*tui.AppModel)
	if !ok {
		closed = appModel
	}
	if cleanup := closed.Close(); cleanup != nil {
		cleanup()
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if err != nil {
		return err
	}
	if m, ok := final.(*tui.AppModel); ok && m.ActiveSession != nil {
		_, err = fmt.Fprintf(t.Out, "To reopen this session, run albedo resume %s\n", m.ActiveSession.ID)
	}
	return err
}

func (t *Service) Login(ctx context.Context, prepared app.PreparedOpen, workspace, name string) error {
	settings, err := t.announceMigration(ctx, prepared.Connection, prepared.Settings)
	if err != nil {
		return err
	}
	if err := tui.DetectInk(); err != nil {
		return err
	}
	leanHeap()
	model := tui.NewLoginAppModel(prepared.Connection, tui.Bootstrap{Settings: settings}, workspace, name, t.OpenBrowser)
	program := tea.NewProgram(model, tea.WithInput(t.In), tea.WithOutput(t.Out))
	stopCancellation := context.AfterFunc(ctx, func() { program.Send(tea.Quit()) })
	defer stopCancellation()
	final, err := program.Run()
	closed, ok := final.(*tui.AppModel)
	if !ok {
		closed = model
	}
	if cleanup := closed.Close(); cleanup != nil {
		cleanup()
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
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

// leanHeap lets the heap grow half past what it holds before collecting,
// not the default doubling: a terminal UI idles at a few kilobytes a second,
// so the extra collections cost nothing a person would see and the resident
// size drops by a sixth. A GOGC set in the environment still wins.
func leanHeap() {
	if os.Getenv("GOGC") == "" {
		debug.SetGCPercent(50)
	}
}
