// Package cli owns command parsing and rendering. Services do not print command output.
package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"albedo/cli/internal/app"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/storage"
	"albedo/cli/internal/terminal"
	"github.com/spf13/cobra"
)

type Dependencies struct {
	Application *app.Service
	Storage     *storage.Service
	Terminal    *terminal.Service
	Workspace   string
}
type Streams struct {
	In       io.Reader
	Out, Err io.Writer
}

// Execute uses a fresh command tree so flags never survive another invocation.
func Execute(ctx context.Context, args []string, deps Dependencies, streams Streams) error {
	output, errorOutput := &checkedWriter{Writer: streams.Out}, &checkedWriter{Writer: streams.Err}
	if deps.Terminal != nil {
		invocationTerminal := *deps.Terminal
		invocationTerminal.In, invocationTerminal.Out, invocationTerminal.Err = streams.In, preserveFile(output), preserveFile(errorOutput)
		deps.Terminal = &invocationTerminal
	}
	root := NewRoot(deps)
	root.SetIn(streams.In)
	root.SetOut(preserveFile(output))
	root.SetErr(preserveFile(errorOutput))
	root.SetArgs(args)
	err := root.ExecuteContext(ctx)
	if outputErr := output.Err(); outputErr != nil && !errors.Is(err, outputErr) {
		err = errors.Join(err, outputErr)
	}
	if stderrErr := errorOutput.Err(); stderrErr != nil && !errors.Is(err, stderrErr) {
		err = errors.Join(err, stderrErr)
	}
	return err
}

// Cobra's help callback cannot return an error. Remember write failures so Execute can.
type checkedWriter struct {
	io.Writer
	err error
	mu  sync.Mutex
}

func (w *checkedWriter) Write(data []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.err != nil {
		return 0, w.err
	}
	count, err := w.Writer.Write(data)
	if err == nil && count < len(data) {
		err = io.ErrShortWrite
	}
	w.err = err
	return count, err
}

func (w *checkedWriter) Err() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.err
}

// Bubble Tea uses the output file descriptor to detect size and terminal modes.
// Keep those methods when tracking writes to an actual file.
type checkedFile struct {
	*os.File
	writer *checkedWriter
}

func (f *checkedFile) Write(data []byte) (int, error)        { return f.writer.Write(data) }
func (f *checkedFile) WriteString(value string) (int, error) { return f.writer.Write([]byte(value)) }

func preserveFile(writer *checkedWriter) io.Writer {
	if file, ok := writer.Writer.(*os.File); ok {
		return &checkedFile{File: file, writer: writer}
	}
	return writer
}

func NewRoot(deps Dependencies) *cobra.Command {
	var prompt, session, model string
	var timeout time.Duration
	root := &cobra.Command{Use: "albedo", Short: "persistent coding sessions", Args: cobra.NoArgs, SilenceErrors: true, SilenceUsage: true}
	root.CompletionOptions.DisableDefaultCmd = true
	root.Flags().StringVarP(&prompt, "prompt", "p", "", "create a session in cwd and wait for its reply")
	root.Flags().StringVarP(&session, "session", "s", "", "send the prompt to an existing session")
	root.Flags().StringVarP(&model, "model", "m", "", "model id or provider/model; requires --prompt")
	root.Flags().DurationVar(&timeout, "timeout", 0, "stop the turn after this long (90s, 10m); unlimited when omitted")
	root.RunE = func(cmd *cobra.Command, _ []string) error {
		if !cmd.Flags().Changed("prompt") {
			for _, name := range []string{"session", "model", "timeout"} {
				if cmd.Flags().Changed(name) {
					return fmt.Errorf("--%s requires --prompt", name)
				}
			}
			return open(cmd, deps, app.OpenOptions{Workspace: deps.Workspace})
		}
		if cmd.Flags().Changed("timeout") && timeout <= 0 {
			return errors.New("--timeout must be positive, such as 90s or 10m")
		}
		ctx, stop := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		result, err := deps.Application.RunPrompt(ctx, app.PromptOptions{Prompt: prompt, SessionID: session, Workspace: deps.Workspace, Model: model, Timeout: timeout})
		if err != nil {
			return err
		}
		_, err = fmt.Fprintln(cmd.OutOrStdout(), result.Answer)
		return err
	}
	root.AddCommand(newOpen(deps), newResume(deps), newSessions(deps), newModels(deps), newSend(deps), newStop(deps), newDaemon(deps), newStorage(deps), newLogin(deps))
	return root
}
func open(cmd *cobra.Command, deps Dependencies, options app.OpenOptions) error {
	options.Terminal = deps.Terminal.Capable
	prepared, err := deps.Application.PrepareOpen(cmd.Context(), options)
	if err != nil {
		return err
	}
	if options.Terminal {
		return deps.Terminal.Open(cmd.Context(), prepared)
	}
	var id *string
	if prepared.Selected != nil {
		id = &prepared.Selected.ID
	}
	if prepared.Sessions == nil {
		prepared.Sessions = []daemon.Session{}
	}
	return writeJSON(cmd.OutOrStdout(), struct {
		Session  *string          `json:"session,omitempty"`
		Sessions []daemon.Session `json:"sessions"`
	}{id, prepared.Sessions}, false)
}
func writeJSON(writer io.Writer, value any, indent bool) error {
	var data []byte
	var err error
	if indent {
		data, err = json.MarshalIndent(value, "", "  ")
	} else {
		data, err = json.Marshal(value)
	}
	if err != nil {
		return err
	}
	_, err = fmt.Fprintln(writer, string(data))
	return err
}
func newOpen(deps Dependencies) *cobra.Command {
	return &cobra.Command{Use: "new [workspace]", Short: "start a fresh session", Args: cobra.MaximumNArgs(1), RunE: func(cmd *cobra.Command, args []string) error {
		workspace := deps.Workspace
		if len(args) > 0 {
			workspace = args[0]
		}
		return open(cmd, deps, app.OpenOptions{Workspace: workspace, Fresh: true})
	}}
}
func newResume(deps Dependencies) *cobra.Command {
	return &cobra.Command{Use: "resume <session>", Short: "reopen a session by ID or prefix", Args: cobra.ExactArgs(1), RunE: func(cmd *cobra.Command, args []string) error {
		return open(cmd, deps, app.OpenOptions{SessionID: args[0], Workspace: deps.Workspace})
	}}
}
func newSessions(deps Dependencies) *cobra.Command {
	var asJSON bool
	command := &cobra.Command{Use: "sessions", Short: "list sessions", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		result, err := deps.Application.Sessions(cmd.Context())
		if err != nil {
			return err
		}
		if result.ArchiveWarning != nil {
			if _, writeErr := fmt.Fprintf(cmd.ErrOrStderr(), "Showing archived sessions too: %v\n", result.ArchiveWarning); writeErr != nil {
				return writeErr
			}
		}
		if asJSON {
			return writeJSON(cmd.OutOrStdout(), result.Sessions, true)
		}
		_, err = fmt.Fprintln(cmd.OutOrStdout(), daemon.SessionListing(result.Sessions, time.Now()))
		return err
	}}
	command.Flags().BoolVar(&asJSON, "json", false, "print sessions as JSON")
	command.AddCommand(newSessionRead(deps), newSend(deps))
	return command
}
func newSessionRead(deps Dependencies) *cobra.Command {
	var asJSON bool
	command := &cobra.Command{Use: "read <session> [turns]", Short: "print a session's newest turns (default 1)", Args: cobra.RangeArgs(1, 2), RunE: func(cmd *cobra.Command, args []string) error {
		turns := 1
		if len(args) == 2 {
			parsed, err := strconv.Atoi(args[1])
			if err != nil || parsed < 1 {
				return fmt.Errorf("turns must be a positive number, got %q", args[1])
			}
			turns = parsed
		}
		result, err := deps.Application.Read(cmd.Context(), args[0], turns)
		if err != nil {
			return err
		}
		if asJSON {
			return writeJSON(cmd.OutOrStdout(), result, true)
		}
		_, err = fmt.Fprint(cmd.OutOrStdout(), renderTurns(result))
		return err
	}}
	command.Flags().BoolVar(&asJSON, "json", false, "print the turns as JSON")
	return command
}

// renderTurns prints what was said and done, one block per event, ending with
// whether the session is still working.
func renderTurns(result app.SessionTurns) string {
	var out strings.Builder
	for _, event := range result.Events {
		switch event.Type {
		case daemon.EventUser:
			fmt.Fprintf(&out, "[user] %s\n", event.Text)
		case daemon.EventMessage:
			fmt.Fprintf(&out, "[assistant] %s\n", event.Text)
		case daemon.EventTool:
			fmt.Fprintf(&out, "[tool] %s\n", event.ToolName)
		case daemon.EventError, daemon.EventNote:
			fmt.Fprintf(&out, "[%s] %s\n", event.Type, event.Text)
		case daemon.EventInterrupted:
			out.WriteString("[interrupted]\n")
		}
	}
	if result.Running {
		out.WriteString("[running] this session is still working; read again for more\n")
	}
	return out.String()
}
func newModels(deps Dependencies) *cobra.Command {
	return &cobra.Command{Use: "models", Short: "list provider/model for every configured provider", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		models, err := deps.Application.Models(cmd.Context())
		if err != nil {
			return err
		}
		for _, model := range models {
			if _, err := fmt.Fprintln(cmd.OutOrStdout(), model); err != nil {
				return err
			}
		}
		return nil
	}}
}
func newSend(deps Dependencies) *cobra.Command {
	return &cobra.Command{Use: "send <session> <prompt>", Short: "send a message to a session", Args: cobra.ExactArgs(2), RunE: func(cmd *cobra.Command, args []string) error {
		result, err := deps.Application.Send(cmd.Context(), args[0], args[1])
		if err != nil {
			return err
		}
		return writeJSON(cmd.OutOrStdout(), result, false)
	}}
}
func newStop(deps Dependencies) *cobra.Command {
	return &cobra.Command{Use: "stop <session>", Short: "interrupt work in a session", Args: cobra.ExactArgs(1), RunE: func(cmd *cobra.Command, args []string) error {
		result, err := deps.Application.Stop(cmd.Context(), args[0])
		if err != nil {
			return err
		}
		return writeJSON(cmd.OutOrStdout(), result, false)
	}}
}
func newDaemon(deps Dependencies) *cobra.Command {
	var stop bool
	command := &cobra.Command{Use: "daemon", Short: "start Albedo in the background or stop it", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		if stop {
			return deps.Application.StopDaemon(cmd.Context())
		}
		conn, err := deps.Application.Connect(cmd.Context())
		if err != nil {
			return err
		}
		_, err = fmt.Fprintf(cmd.OutOrStdout(), "Albedo is running in the background at 127.0.0.1:%d\n", conn.Port())
		return err
	}}
	command.Flags().BoolVar(&stop, "stop", false, "stop the running daemon")
	return command
}
func newLogin(deps Dependencies) *cobra.Command {
	return &cobra.Command{Use: "login [name]", Short: "set up a model provider in a terminal", Args: cobra.MaximumNArgs(1), RunE: func(cmd *cobra.Command, args []string) error {
		if !deps.Terminal.Capable {
			return errors.New("run albedo login in a terminal so you can enter your API key without displaying it")
		}
		name := ""
		if len(args) > 0 {
			name = args[0]
		}
		prepared, err := deps.Application.PrepareLogin(cmd.Context())
		if err != nil {
			return err
		}
		return deps.Terminal.Login(cmd.Context(), prepared, deps.Workspace, name)
	}}
}
