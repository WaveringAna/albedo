// Editor failures must not lose saved edits or leave prompt files behind,
// and a clicked row must name the right file and line in every way a path is
// written. The daemon E2E driver does not run the prompt editor, and E2E
// clicks one row of each kind rather than every spelling of a path.
package tui

import (
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
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

func TestFileTargetAtReadsEverySpellingOfAPath(t *testing.T) {
	ws := t.TempDir()
	for _, name := range []string{"main.go", "sub/util.go"} {
		path := filepath.Join(ws, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	main, util := filepath.Join(ws, "main.go"), filepath.Join(ws, "sub", "util.go")
	for _, c := range []struct {
		line string
		col  int
		want FileTarget // zero when nothing opens
	}{
		{"error at main.go:42:15: failed", 12, FileTarget{main, 42, 15}},
		{"main.go:42:", 0, FileTarget{main, 42, 0}},
		{`files.read(path="sub/util.go")`, 20, FileTarget{util, 0, 0}},
		{"see `sub/util.go#L10`.", 8, FileTarget{util, 10, 0}},
		{"+++ b/sub/util.go", 8, FileTarget{util, 0, 0}},
		{"file://" + main + ":3", 10, FileTarget{main, 3, 0}},
		{"compare main.go with sub/util.go", 10, FileTarget{main, 0, 0}},
		{"compare main.go with sub/util.go", 25, FileTarget{util, 0, 0}},
		{"compare main.go with sub/util.go", 0, FileTarget{}},
		{"I updated sub/util.go here", 0, FileTarget{util, 0, 0}},
		{"wide 漢字 main.go", 10, FileTarget{main, 0, 0}},
		{"see https://example.com/main.go", 10, FileTarget{}},
		{"missing.go and plain words", 2, FileTarget{}},
	} {
		got, _ := fileTargetAt(c.line, c.col, ws)
		if got != c.want {
			t.Errorf("%q at %d: got %+v, want %+v", c.line, c.col, got, c.want)
		}
	}
}
