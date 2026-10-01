package tui

import (
	"cmp"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func (m ChatModel) openEditorCmd() tea.Cmd {
	args := strings.Fields(cmp.Or(os.Getenv("EDITOR"), os.Getenv("VISUAL"), "nano"))
	if len(args) == 0 {
		args = []string{"nano"}
	}
	process := &promptEditorProcess{
		editorProcess: editorProcess{exec.Command(args[0], args[1:]...), m.graphemes},
		prompt:        m.TextArea.Value(),
	}
	sessionID, generation := m.SessionID, m.Generation
	return tea.Exec(process, func(err error) tea.Msg {
		return ChatEditorFinishedMsg{SessionID: sessionID, Generation: generation, Text: process.text, Edited: process.edited, Err: err}
	})
}

// promptEditorProcess owns the prompt file for the complete editor operation.
// Its completion message carries text even when the UI no longer owns the session.
type promptEditorProcess struct {
	editorProcess
	prompt string
	text   string
	edited bool
}

func (p *promptEditorProcess) Run() error {
	file, err := os.CreateTemp("", "albedo-prompt-*.md")
	if err != nil {
		return fmt.Errorf("could not create temporary file: %w", err)
	}
	path := file.Name()
	defer os.Remove(path)
	if _, err := file.WriteString(p.prompt); err != nil {
		file.Close()
		return fmt.Errorf("could not write to temporary file: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("could not close temporary file: %w", err)
	}

	p.Args = append(p.Args, path)
	commandErr, restoreErr := p.runAndRestore()
	if commandErr != nil {
		return errors.Join(commandErr, restoreErr)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return errors.Join(fmt.Errorf("could not read the edited prompt: %w", err), restoreErr)
	}
	p.text = string(data)
	p.edited = true
	return restoreErr
}

// editorProcess runs the editor on the terminal, then hands the terminal back
// the way Bubble Tea left it. Bubble Tea repaints from where it left the
// cursor and trusts the column, but leaving the alternate screen puts the
// cursor back wherever the editor found it, and a terminal reply echoed
// before the editor took raw mode can have moved it along the row; the
// repaint then starts mid-row, wraps the header and scrolls it off the top.
// Bubble Tea also turns grapheme widths off for the editor and never turns
// them back on, while it keeps measuring by grapheme.
type editorProcess struct {
	*exec.Cmd
	graphemes bool
}

func (p editorProcess) SetStdin(r io.Reader)  { p.Stdin = r }
func (p editorProcess) SetStdout(w io.Writer) { p.Stdout = w }
func (p editorProcess) SetStderr(w io.Writer) { p.Stderr = w }

func (p editorProcess) Run() error {
	return errors.Join(p.runAndRestore())
}

func (p editorProcess) runAndRestore() (commandErr, restoreErr error) {
	commandErr = p.Cmd.Run()
	restore := "\r"
	if p.graphemes {
		restore += ansi.SetModeUnicodeCore
	}
	written, err := io.WriteString(p.Stdout, restore)
	if err == nil && written != len(restore) {
		err = io.ErrShortWrite
	}
	if err != nil {
		restoreErr = fmt.Errorf("could not restore terminal output after the editor: %w", err)
	}
	return commandErr, restoreErr
}
