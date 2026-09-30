// The composer loses user input and breaks its frame in ways only keystrokes
// and a real wrapping layout reveal: the daemon never sees a keystroke, and
// the e2e harness drives the TUI in process with no PTY, so wrap boundaries,
// scroll behavior, terminal handoff around the editor, and grapheme widths
// cannot be observed there. Async status ordering is controlled here because
// real HTTP cannot deterministically deliver a superseded reply after a reset.
package tui

import (
	"fmt"
	"os/exec"
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// composer sizes a chat like a small terminal.
func composer(t *testing.T, width, height int) ChatModel {
	t.Helper()
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(width, height)
	return m
}

func typePrompt(m ChatModel, text string) ChatModel {
	for _, r := range text {
		m, _ = m.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	return m
}

// frame checks the chat view is exactly height rows with the separator
// directly above the footer, and hands back the stripped rows.
func frame(t *testing.T, m ChatModel, height int) []string {
	t.Helper()
	lines := strings.Split(ansi.Strip(m.View()), "\n")
	if len(lines) != height {
		t.Fatalf("view is %d rows, want %d", len(lines), height)
	}
	if !strings.Contains(lines[len(lines)-2], "─") {
		t.Fatalf("expected the separator above the footer, got %q", lines[len(lines)-2])
	}
	if !strings.Contains(lines[len(lines)-1], "/ commands") {
		t.Fatalf("expected the footer last, got %q", lines[len(lines)-1])
	}
	return lines
}

// One interaction scenario: a long prompt wraps without losing text or
// leaving a blank row, cursor keys move inside the wrap without scrolling the
// transcript, submit resets the layout, alt+enter adds a line, and a prompt
// past six visual rows scrolls inside the cap without a character limit.
func TestPromptMultilineWrapsScrollsAndSubmits(t *testing.T) {
	const width, height = 60, 25
	altEnter := tea.KeyPressMsg{Code: tea.KeyEnter, Mod: tea.ModAlt}
	m := composer(t, width, height)

	// enter while connecting keeps the draft instead of sending it.
	m = typePrompt(m, "too early")
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.TextArea.Value() != "too early" || len(m.pendingUsers) != 0 {
		t.Fatalf("enter while connecting sent %q (pending %d), want the draft kept", m.TextArea.Value(), len(m.pendingUsers))
	}
	m.TextArea.Reset()
	m.Status.Phase = &phaseResting

	if m.promptHeight() != 1 {
		t.Fatalf("initial promptHeight %d, want 1", m.promptHeight())
	}
	resting := height - 6 - m.chromeRows()
	if m.Viewport.Height() != resting {
		t.Fatalf("viewport height %d, want %d", m.Viewport.Height(), resting)
	}
	frame(t, m, height)

	long := "this is a very long prompt sentence that should definitely wrap across multiple lines in a sixty column terminal"
	m = typePrompt(m, long)
	if m.promptHeight() <= 1 {
		t.Fatalf("promptHeight %d, want the long line wrapped", m.promptHeight())
	}
	lines := frame(t, m, height)
	if view := ansi.Strip(m.View()); !strings.Contains(view, "this is a very long prompt") {
		t.Fatalf("the prompt's first row vanished from the view:\n%s", view)
	}
	if m.TextArea.Value() != long {
		t.Fatalf("typing lost input: %q", m.TextArea.Value())
	}
	if last := strings.TrimSpace(lines[len(lines)-3]); last == "" {
		t.Fatalf("the prompt has an empty row above the separator: %q", lines[len(lines)-3])
	}

	// Cursor keys move inside the wrapped prompt and never scroll the
	// transcript.
	m.TextArea.CursorStart()
	if m.TextArea.Line() != 0 || m.TextArea.LineInfo().RowOffset != 0 {
		t.Fatalf("cursor not at the start: line=%d rowOffset=%d", m.TextArea.Line(), m.TextArea.LineInfo().RowOffset)
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
	if m.TextArea.LineInfo().RowOffset != 1 {
		t.Fatalf("rowOffset %d after KeyDown, want 1", m.TextArea.LineInfo().RowOffset)
	}
	beforeScroll := m.scrollOffset
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyUp})
	if m.TextArea.LineInfo().RowOffset != 0 {
		t.Fatalf("rowOffset %d after KeyUp, want 0", m.TextArea.LineInfo().RowOffset)
	}
	if m.scrollOffset != beforeScroll {
		t.Fatalf("KeyUp in the middle of the prompt scrolled the transcript: before=%d after=%d", beforeScroll, m.scrollOffset)
	}

	// Submit resets the prompt to one line and gives the viewport its height
	// back.
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.promptHeight() != 1 {
		t.Fatalf("promptHeight %d after Enter, want 1", m.promptHeight())
	}
	if m.Viewport.Height() != resting {
		t.Fatalf("viewport height %d after Enter, want %d", m.Viewport.Height(), resting)
	}

	// Alt+enter adds a line instead of submitting.
	m = typePrompt(m, "hello")
	m, _ = m.Update(altEnter)
	m = typePrompt(m, "world")
	if m.promptHeight() != 2 {
		t.Fatalf("promptHeight %d after alt+enter, want 2", m.promptHeight())
	}
	frame(t, m, height)

	// Ten alt+enter lines exceed every limit: the value keeps every
	// character, the prompt caps at six visual rows, and the latest line
	// stays visible in the scrolled view.
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	for i := 1; i <= 10; i++ {
		m = typePrompt(m, fmt.Sprintf("line %d with plenty of characters to exceed 400 total chars across all lines", i))
		_ = m.View()
		if i < 10 {
			m, _ = m.Update(altEnter)
			_ = m.View()
		}
	}
	if len(m.TextArea.Value()) <= 400 {
		t.Fatalf("prompt kept only %d chars, want every line", len(m.TextArea.Value()))
	}
	if m.promptHeight() != 6 {
		t.Fatalf("promptHeight %d, want the six-row cap", m.promptHeight())
	}
	frame(t, m, height)
	if view := ansi.Strip(m.View()); !strings.Contains(view, "line 10") {
		t.Fatalf("line 10 is not visible in the scrolled view:\n%s", view)
	}
}

// The repaint after the editor starts wherever the cursor is, so the editor
// process must hand the terminal back at the start of a row, with grapheme
// widths back on when the terminal had them. Only a real child process and
// its escape sequences exercise this.
func TestEditorProcessRestoresTerminal(t *testing.T) {
	for _, tc := range []struct {
		want      string
		graphemes bool
	}{
		{graphemes: false, want: "echoed reply\r"},
		{graphemes: true, want: "echoed reply\r" + ansi.SetModeUnicodeCore},
	} {
		var out strings.Builder
		p := editorProcess{exec.Command("sh", "-c", "printf 'echoed reply'"), tc.graphemes}
		p.SetStdout(&out)
		if err := p.Run(); err != nil {
			t.Fatal(err)
		}
		if out.String() != tc.want {
			t.Fatalf("graphemes %v: expected %q, got %q", tc.graphemes, tc.want, out.String())
		}
	}
}

// A terminal without mode 2027 must not measure graphemes, and one that
// reports the mode keeps the setting across chats. The report only exists in
// a real terminal, so no e2e surface carries it.
func TestAppRemembersGraphemeTerminal(t *testing.T) {
	m := AppModel{Conn: daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, t.TempDir())}
	next, _ := m.Update(tea.ModeReportMsg{Mode: ansi.ModeUnicodeCore, Value: ansi.ModeNotRecognized})
	if next.(AppModel).Graphemes {
		t.Fatal("a terminal without mode 2027 does not measure graphemes")
	}
	next, _ = next.Update(tea.ModeReportMsg{Mode: ansi.ModeUnicodeCore, Value: ansi.ModeReset})
	app := next.(AppModel)
	if !app.Graphemes || !app.Chat.graphemes {
		t.Fatal("expected the app and its chat to remember grapheme widths")
	}
	if chat := app.newChatModel(&daemon.Session{ID: "s"}); !chat.graphemes {
		t.Fatal("expected a new chat to inherit grapheme widths")
	}
}

// The order of a reset and status replies is controlled here: real HTTP cannot
// deterministically deliver a superseded status after a snapshot arrives.
func TestComposerIgnoresStaleStatusAndAcceptsIdleWithoutPhase(t *testing.T) {
	const draft = "keep this draft"
	m := composer(t, 80, 22)
	defer m.Close()
	status := ChatStatusMsg{
		SessionID: m.SessionID, Generation: m.Generation,
		Revision: m.statusRevision, Status: &daemon.AgentStatus{Idle: true},
	}
	m, _ = m.Update(ChatStreamEventMsg{
		SessionID: m.SessionID, Generation: m.Generation,
		Event: daemon.StreamEvent{Type: daemon.EventReset},
	})
	m, _ = m.Update(status)
	m = typePrompt(m, draft)
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.TextArea.Value() != draft || len(m.pendingUsers) != 0 {
		t.Fatal("a stale status unblocked the composer")
	}
	status.Revision = m.statusRevision
	m, _ = m.Update(status)
	m.TextArea.Reset()
	if !strings.Contains(ansi.Strip(m.View()), "ctrl+g editor") {
		t.Fatal("an idle status without a phase did not restore the input cue")
	}
	m.TextArea.SetValue(draft)
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	pending := m.pendingUsers
	if m.TextArea.Value() != "" || len(pending) != 1 || pending[0].Text != draft {
		t.Fatal("an idle status without a phase refused the draft")
	}
}
