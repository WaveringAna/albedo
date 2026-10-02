package terminal

import (
	"context"
	"fmt"
	"strings"

	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
)

// ConfirmRestart keeps input cancellation owned by Bubble Tea, rather than
// leaving a blocked reader behind when the caller stops waiting.
func (t *Service) ConfirmRestart(ctx context.Context, running daemon.ConnectionSnapshot, selectedBuild string) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if !t.Capable {
		return false, nil
	}
	if _, err := fmt.Fprintf(t.Out, "Albedo is already running (PID %d).\n", running.Pid); err != nil {
		return false, err
	}
	if running.Build != "" && selectedBuild != "" && running.Build != selectedBuild {
		if _, err := fmt.Fprintln(t.Out, "The running daemon comes from a different build."); err != nil {
			return false, err
		}
	}
	if _, err := fmt.Fprintln(t.Out, "Restarting interrupts active work in all sessions. Keep it running unless you want to restart."); err != nil {
		return false, err
	}
	program := tea.NewProgram(restartConfirmation{}, tea.WithInput(t.In), tea.WithOutput(t.Out), tea.WithoutSignalHandler())
	// Graceful quit waits for the canceled input reader before closing it.
	// WithContext kills immediately and can race that reader's shutdown.
	stopCancellation := context.AfterFunc(ctx, func() { program.Send(tea.Quit()) })
	defer stopCancellation()
	final, err := program.Run()
	if ctx.Err() != nil {
		return false, ctx.Err()
	}
	if err != nil {
		return false, err
	}
	answer := final.(restartConfirmation)
	return Confirmed(answer.input), answer.err
}

type restartConfirmation struct {
	input string
	err   error
}

func (m restartConfirmation) Init() tea.Cmd { return nil }

func (m restartConfirmation) Update(message tea.Msg) (tea.Model, tea.Cmd) {
	switch message := message.(type) {
	case tea.KeyPressMsg:
		switch message.String() {
		case "ctrl+c", "ctrl+d", "esc":
			m.err = context.Canceled
			return m, tea.Quit
		case "enter":
			return m, tea.Quit
		case "backspace":
			characters := []rune(m.input)
			if len(characters) > 0 {
				m.input = string(characters[:len(characters)-1])
			}
		default:
			m.input += message.Text
		}
	case tea.PasteMsg:
		m.input += strings.ReplaceAll(strings.ReplaceAll(message.Content, "\r", ""), "\n", "")
	}
	return m, nil
}

func (m restartConfirmation) View() tea.View {
	return tea.NewView("Restart Albedo? [y/N] " + m.input)
}
