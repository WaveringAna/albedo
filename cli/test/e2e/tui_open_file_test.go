//go:build unix

// Ctrl-click opens the file a transcript row names in the editor, at its
// line. The rows come from the real renderer and a real files.write diff,
// and the click lands on screen coordinates, so a change to how rows are
// drawn or clicks are mapped breaks this test rather than the feature.
package e2e

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui"

	tea "charm.land/bubbletea/v2"
)

func TestTUICtrlClickOpensTheNamedFileInTheEditor(t *testing.T) {
	profile := providerRoute(t, func(request map[string]any) string {
		if toolAnswered(request) {
			return "I fixed main.go:3:6 for you."
		}
		return pythonCall(`files.write("main.go", "package main\n\nfunc main() {}\n")`)
	})
	workspace := t.TempDir()
	session := daemonSession(t, newSession(t, workspace))
	if _, err := daemon.NewChatClient(conn(t), session.ID).Send(t.Context(), "fix main", nil); err != nil {
		t.Fatal(err)
	}
	waitIdle(t, session.ID, profile, 2)

	// albedo runs in Zed's terminal, so the file opens through zed, which
	// here only writes down what it was asked to open.
	bin, opened := t.TempDir(), filepath.Join(t.TempDir(), "opened")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > " + opened + ".tmp && mv " + opened + ".tmp " + opened + "\n"
	if err := os.WriteFile(filepath.Join(bin, "zed"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("TERM_PROGRAM", "zed")
	t.Setenv("EDITOR", "false")

	d := driveTUI(t, &session)
	t.Cleanup(d.App.Chat.Close)
	d.Update(tea.WindowSizeMsg{Width: 100, Height: 50})
	pumpStreamUntil(t, d, func(msg tea.Msg) bool {
		event, ok := msg.(tui.ChatStreamEventMsg)
		return ok && strings.Contains(event.Event.Text, "I fixed main.go")
	})
	file := filepath.Join(workspace, "main.go")

	// at is the screen cell of text's third character.
	at := func(text string) (x, y int) {
		t.Helper()
		view := d.View()
		for y, row := range strings.Split(view, "\n") {
			if i := strings.Index(row, text); i >= 0 {
				return len([]rune(row[:i])) + 2, y
			}
		}
		t.Fatalf("no row shows %q:\n%s", text, view)
		return 0, 0
	}
	ctrlClick := func(text string) string {
		t.Helper()
		x, y := at(text)
		_ = os.Remove(opened)
		d.Update(tea.MouseClickMsg{X: x, Y: y, Button: tea.MouseLeft, Mod: tea.ModCtrl})
		result := d.Send(tea.MouseReleaseMsg{X: x, Y: y, Button: tea.MouseLeft, Mod: tea.ModCtrl})
		if done, ok := result.(tui.FileOpenResultMsg); !ok || done.Err != nil {
			t.Fatalf("ctrl-click on %q did not open a file: %#v\n%s", text, result, d.View())
		}
		for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
			if got, err := os.ReadFile(opened); err == nil {
				return strings.TrimSpace(string(got))
			}
		}
		t.Fatalf("the editor never ran for %q", text)
		return ""
	}

	if got, want := ctrlClick("main.go:3:6"), file+":3:6"; got != want {
		t.Fatalf("a reply's path opened %q, want %q", got, want)
	}
	if got := ctrlClick("edited main.go"); got != file {
		t.Fatalf("the folded edit row opened %q, want %q", got, file)
	}
	// ctrl+j shows diffs, and a diff row names its line
	d.Dispatch(tea.KeyPressMsg{Code: 'j', Mod: tea.ModCtrl})
	if got, want := ctrlClick("func main() {}"), file+":3"; got != want {
		t.Fatalf("a diff row opened %q, want %q", got, want)
	}
}
