// Editor failures must not lose saved edits or leave prompt files behind.
// The daemon E2E driver does not execute the local editor process.
package tui

import (
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"testing"
)

type restorationWriter struct {
	err   error
	short bool
}

func (writer restorationWriter) Write(data []byte) (int, error) {
	if writer.err != nil || writer.short {
		return 0, writer.err
	}
	return len(data), nil
}

func TestPromptEditorPreservesEditsAndCleansUp(t *testing.T) {
	shell, err := exec.LookPath("sh")
	if err != nil {
		t.Skip("shell unavailable")
	}
	restoreFailure := errors.New("output unavailable")
	for _, scenario := range []struct {
		name, script, text string
		writer             restorationWriter
		wantRestore        error
		wantEdited         bool
		wantExit           bool
	}{
		{"success", `printf '%s' "$1" >&2; printf 'edited' > "$1"`, "edited", restorationWriter{}, nil, true, false},
		{"saved edits", `printf '%s' "$1" >&2; printf 'edited' > "$1"`, "edited", restorationWriter{err: restoreFailure}, restoreFailure, true, false},
		{"empty edits", `printf '%s' "$1" >&2; : > "$1"`, "", restorationWriter{err: restoreFailure}, restoreFailure, true, false},
		{"short write", `printf '%s' "$1" >&2; printf 'edited' > "$1"`, "edited", restorationWriter{short: true}, io.ErrShortWrite, true, false},
		{"execution and restoration", `printf '%s' "$1" >&2; exit 7`, "", restorationWriter{err: restoreFailure}, restoreFailure, false, true},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			t.Setenv("TMPDIR", t.TempDir())
			process := &promptEditorProcess{
				editorProcess: editorProcess{Cmd: exec.Command(shell, "-c", scenario.script, "editor")},
				prompt:        "original",
			}
			var path strings.Builder
			process.SetStderr(&path)
			process.SetStdout(scenario.writer)
			err := process.Run()
			if !errors.Is(err, scenario.wantRestore) {
				t.Fatalf("restoration error lost: %v", err)
			}
			_, hasExit := errors.AsType[*exec.ExitError](err)
			if hasExit != scenario.wantExit {
				t.Fatalf("execution error lost: %v", err)
			}
			if process.edited != scenario.wantEdited || process.text != scenario.text {
				t.Fatalf("edited=%v text=%q", process.edited, process.text)
			}
			if path.String() == "" {
				t.Fatal("editor did not receive a temporary file")
			}
			if _, err := os.Stat(path.String()); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("temporary file survived: %v", err)
			}
		})
	}
}

func TestEditorCompletionPreservesTextAndReportsRestorationFailure(t *testing.T) {
	for _, scenario := range []struct {
		name, text string
		stale      bool
	}{
		{"saved edits", "edited", false},
		{"empty edits", "", false},
		{"stale completion", "edited", true},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			model := composer(t, 80, 24)
			model.TextArea.SetValue("original")
			message := ChatEditorFinishedMsg{
				SessionID: model.SessionID, Generation: model.Generation,
				Text: scenario.text, Edited: true, Err: errors.New("restore failed"),
			}
			if scenario.stale {
				message.Generation++
			}
			model, _ = model.Update(message)
			wantText := scenario.text
			if scenario.stale {
				wantText = "original"
			}
			if model.TextArea.Value() != wantText || model.Notices.HasError() == scenario.stale {
				t.Fatalf("text=%q, error notice=%v", model.TextArea.Value(), model.Notices.HasError())
			}
		})
	}
}
