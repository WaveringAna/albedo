package tui

import (
	"cmp"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"albedo/cli/internal/daemon"
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

// FileTarget is a file location clicked in the transcript.
type FileTarget struct {
	Path      string
	Line, Col int
}

var (
	// pathToken is a run of text that quotes, brackets, and spaces end.
	pathToken = regexp.MustCompile("[^\\s\"'`()\\[\\]{}<>]+")
	// position is a trailing :line[:col] or #Lline.
	position   = regexp.MustCompile(`(?::(\d+)(?::(\d+))?|#L(\d+))$`)
	diffGutter = regexp.MustCompile(`^\s*(\d+) [+\- ] `)
)

// openFileAt opens the file named at transcript position (row, col).
func (m *ChatModel) openFileAt(row, col int) tea.Cmd {
	if row < 0 || row >= len(m.frameLines) {
		return nil
	}
	target, ok := fileTargetAt(ansi.Strip(m.frameLines[row]), col, m.Workspace)
	if !ok {
		target, ok = m.diffTargetAt(row)
	}
	if !ok {
		return nil
	}
	return m.openFileCmd(target)
}

// diffTargetAt names the line of a diff row: the path is the first row above
// it that is neither a numbered row nor a hunk header.
func (m *ChatModel) diffTargetAt(row int) (FileTarget, bool) {
	gutter := diffGutter.FindStringSubmatch(rowBody(m.frameLines[row]))
	if gutter == nil {
		return FileTarget{}, false
	}
	for prev := row - 1; prev >= 0; prev-- {
		above := rowBody(m.frameLines[prev])
		if diffGutter.MatchString(above) || strings.Contains(above, "@@") {
			continue
		}
		target, ok := fileTargetAt(above, 0, m.Workspace)
		target.Line, _ = strconv.Atoi(gutter[1])
		target.Col = 0
		return target, ok
	}
	return FileTarget{}, false
}

// rowBody is a transcript row's plain text after its rail.
func rowBody(row string) string {
	plain := ansi.Strip(row)
	return ansi.Cut(plain, railWidth, ansi.StringWidth(plain))
}

// fileTargetAt is the existing file named by the token under column col of
// plain, else the only existing file plain names.
func fileTargetAt(plain string, col int, workspace string) (FileTarget, bool) {
	at := len(ansi.Truncate(plain, col, ""))
	var found []FileTarget
	for _, span := range pathToken.FindAllStringIndex(plain, -1) {
		target, ok := parseTarget(plain[span[0]:span[1]], workspace)
		if !ok {
			continue
		}
		if span[0] <= at && at <= span[1] {
			return target, true
		}
		found = append(found, target)
	}
	if len(found) == 1 {
		return found[0], true
	}
	return FileTarget{}, false
}

// parseTarget reads a token such as path=a/x.go:12:3 or file://x.go#L4,
// keeping it only when it names a file that exists.
func parseTarget(token, workspace string) (FileTarget, bool) {
	token = strings.TrimRight(token, ".,;:")
	if strings.Contains(token, "://") && !strings.HasPrefix(token, "file://") {
		return FileTarget{}, false
	}
	token = strings.TrimPrefix(token, "file://")
	if _, after, ok := strings.Cut(token, "="); ok {
		token = after
	}
	var target FileTarget
	if loc := position.FindStringSubmatchIndex(token); loc != nil {
		groups := position.FindStringSubmatch(token)
		target.Line, _ = strconv.Atoi(groups[1] + groups[3])
		target.Col, _ = strconv.Atoi(groups[2])
		token = token[:loc[0]]
	}
	if token == "" {
		return FileTarget{}, false
	}
	home, _ := os.UserHomeDir()
	_, root := daemon.SplitLocation(workspace)
	paths := []string{token}
	// a diff's a/ and b/ prefixes
	if rest, ok := strings.CutPrefix(token, "a/"); ok {
		paths = append(paths, rest)
	} else if rest, ok := strings.CutPrefix(token, "b/"); ok {
		paths = append(paths, rest)
	}
	for _, p := range paths {
		p = expandHome(p, home)
		if !filepath.IsAbs(p) {
			p = filepath.Join(cmp.Or(root, "."), p)
		}
		if info, err := os.Stat(p); err == nil && info.Mode().IsRegular() {
			target.Path, _ = filepath.Abs(p)
			return target, true
		}
	}
	return FileTarget{}, false
}

func (m ChatModel) openFileCmd(target FileTarget) tea.Cmd {
	bin, args, terminal := detectEditor(target)
	sessionID := m.SessionID
	if terminal {
		process := editorProcess{exec.Command(bin, args...), m.graphemes}
		return tea.Exec(process, func(err error) tea.Msg {
			return FileOpenResultMsg{SessionID: sessionID, Target: target, Err: err}
		})
	}
	return func() tea.Msg {
		cmd := exec.Command(bin, args...)
		err := cmd.Start()
		if err == nil {
			go cmd.Wait()
		}
		return FileOpenResultMsg{SessionID: sessionID, Target: target, Err: err}
	}
}

// guiEditors open a file in a window of their own and return at once; how
// each takes a line is in editorArgs.
var guiEditors = []string{"code", "cursor", "windsurf", "codium", "zed", "subl"}

// detectEditor picks the IDE whose terminal albedo runs in, else $EDITOR,
// and says whether the editor needs this terminal.
func detectEditor(target FileTarget) (bin string, args []string, terminal bool) {
	if ide := terminalIDE(); ide != "" {
		if path, err := exec.LookPath(ide); err == nil {
			return path, editorArgs(ide, target), false
		}
	}
	fields := strings.Fields(cmp.Or(os.Getenv("EDITOR"), os.Getenv("VISUAL"), "nano"))
	base := filepath.Base(fields[0])
	return fields[0], append(fields[1:], editorArgs(base, target)...), !slices.Contains(guiEditors, base)
}

// terminalIDE names the CLI of the editor whose integrated terminal this is.
func terminalIDE() string {
	env := os.Getenv
	switch {
	case env("TERM_PROGRAM") == "zed" || env("ZED_TERM") != "":
		return "zed"
	case env("TERM_PROGRAM") != "vscode" && env("VSCODE_PID") == "":
		return ""
	case env("CURSOR_TRACE_ID") != "" || env("CURSOR_VERSION") != "":
		return "cursor"
	case env("WINDSURF_VERSION") != "":
		return "windsurf"
	}
	return "code"
}

func editorArgs(editor string, t FileTarget) []string {
	at := t.Path
	if t.Line > 0 {
		at += ":" + strconv.Itoa(t.Line)
		if t.Col > 0 {
			at += ":" + strconv.Itoa(t.Col)
		}
	}
	switch {
	case t.Line == 0:
		return []string{t.Path}
	case editor == "code" || editor == "cursor" || editor == "windsurf" || editor == "codium":
		return []string{"-g", at}
	case editor == "zed" || editor == "subl" || editor == "hx":
		return []string{at}
	}
	// vi, nano, emacs, and most others
	return []string{"+" + strconv.Itoa(t.Line), t.Path}
}
