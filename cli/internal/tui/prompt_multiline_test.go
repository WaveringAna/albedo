package tui

import (
	"fmt"
	"os"
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func TestPromptMultilineWrappingAndSeparators(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s"}, nil)
	width := 60
	height := 25
	m.SetSize(width, height)

	// Single line prompt initial state
	if m.promptHeight() != 1 {
		t.Fatalf("expected initial promptHeight to be 1, got %d", m.promptHeight())
	}
	expectedVpHeight := height - 6 - m.chromeRows()
	if m.Viewport.Height != expectedVpHeight {
		t.Fatalf("expected viewport height %d, got %d", expectedVpHeight, m.Viewport.Height)
	}

	// Verify view has top separator, prompt, bottom separator, and footer
	view := ansi.Strip(m.View())
	lines := strings.Split(view, "\n")
	if len(lines) != height {
		t.Fatalf("expected view to have %d lines, got %d", height, len(lines))
	}

	// Last line is footer, second to last is bottom separator
	if !strings.Contains(lines[len(lines)-2], "─") {
		t.Fatalf("expected bottom separator above footer, line was: %q", lines[len(lines)-2])
	}
	if !strings.Contains(lines[len(lines)-1], "/ commands") {
		t.Fatalf("expected footer on last line, got: %q", lines[len(lines)-1])
	}

	// Now type long text that should wrap to multiple lines
	longText := "this is a very long prompt sentence that should definitely wrap across multiple lines in a sixty column terminal"
	for _, r := range longText {
		m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}

	if m.promptHeight() <= 1 {
		t.Fatalf("expected promptHeight > 1 after typing long text, got %d", m.promptHeight())
	}

	// Viewport height should have shrunk by (promptHeight - 1)
	expectedNewVpHeight := height - 6 - m.chromeRows()
	if m.Viewport.Height != expectedNewVpHeight {
		t.Fatalf("expected viewport height %d, got %d", expectedNewVpHeight, m.Viewport.Height)
	}

	// Rendered view must still exactly equal terminal height
	view2 := ansi.Strip(m.View())
	lines2 := strings.Split(view2, "\n")
	if len(lines2) != height {
		t.Fatalf("expected view to have %d lines with multiline prompt, got %d", height, len(lines2))
	}

	// Verify bottom separator still sits right above the footer
	if !strings.Contains(lines2[len(lines2)-2], "─") {
		t.Fatalf("expected bottom separator above footer with multiline prompt, got: %q", lines2[len(lines2)-2])
	}
	if !strings.Contains(lines2[len(lines2)-1], "/ commands") {
		t.Fatalf("expected footer on last line with multiline prompt, got: %q", lines2[len(lines2)-1])
	}

	// Up/Down navigation within wrapped lines:
	// Move cursor to top line of textarea
	m.TextArea.CursorStart()
	if m.TextArea.Line() != 0 || m.TextArea.LineInfo().RowOffset != 0 {
		t.Fatalf("expected cursor at start, line=%d rowOffset=%d", m.TextArea.Line(), m.TextArea.LineInfo().RowOffset)
	}

	// Move cursor down one visual line
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyDown})
	if m.TextArea.LineInfo().RowOffset != 1 {
		t.Fatalf("expected rowOffset 1 after KeyDown, got %d", m.TextArea.LineInfo().RowOffset)
	}

	// Up key while not on row 0 should move up inside textarea, NOT scroll viewport
	beforeScroll := m.scrollOffset
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyUp})
	if m.TextArea.LineInfo().RowOffset != 0 {
		t.Fatalf("expected rowOffset 0 after KeyUp, got %d", m.TextArea.LineInfo().RowOffset)
	}
	if m.scrollOffset != beforeScroll {
		t.Fatalf("KeyUp in middle of prompt should not scroll transcript: before=%d after=%d", beforeScroll, m.scrollOffset)
	}

	// Submit should reset prompt back to 1 line and restore viewport height
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if m.promptHeight() != 1 {
		t.Fatalf("expected promptHeight to reset to 1 after Enter, got %d", m.promptHeight())
	}
	if m.Viewport.Height != expectedVpHeight {
		t.Fatalf("expected viewport height restored to %d after Enter, got %d", expectedVpHeight, m.Viewport.Height)
	}
}

func TestPromptAltEnterNewline(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s"}, nil)
	m.SetSize(60, 25)

	// Type first line
	for _, r := range "hello" {
		m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}
	if m.promptHeight() != 1 {
		t.Fatalf("expected promptHeight 1, got %d", m.promptHeight())
	}

	// Press Alt+Enter to insert a newline
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter, Alt: true})
	for _, r := range "world" {
		m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}

	if m.promptHeight() != 2 {
		t.Fatalf("expected promptHeight 2 after Alt+Enter, got %d", m.promptHeight())
	}

	lines := strings.Split(ansi.Strip(m.View()), "\n")
	if len(lines) != 25 {
		t.Fatalf("expected 25 lines total, got %d", len(lines))
	}
}

func TestPromptWrappingInteractiveKeystrokesNoLossNoBlankBottom(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s"}, nil)
	m.SetSize(40, 20)

	text := "this is a line of text that wraps around right now"
	for _, r := range text {
		m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
		// In interactive TUI, View() is rendered after every keystroke
		view := ansi.Strip(m.View())
		lines := strings.Split(view, "\n")
		if len(lines) != 20 {
			t.Fatalf("expected 20 lines on every frame, got %d", len(lines))
		}
	}

	view := ansi.Strip(m.View())
	if !strings.Contains(view, "this is a line of text that wraps") {
		t.Fatalf("first line disappeared after typing! view:\n%s", view)
	}
	if !strings.Contains(view, "around right now") {
		t.Fatalf("wrapped second line is missing! view:\n%s", view)
	}

	// Verify that the prompt section does NOT have an empty blank line before the bottom separator
	lines := strings.Split(view, "\n")
	bottomSepIdx := len(lines) - 2
	if !strings.Contains(lines[bottomSepIdx], "─") {
		t.Fatalf("expected separator at line %d, got %q", bottomSepIdx, lines[bottomSepIdx])
	}
	lastPromptLine := strings.TrimSpace(lines[bottomSepIdx-1])
	if lastPromptLine == "" {
		t.Fatalf("prompt has an empty line above bottom separator: %q", lines[bottomSepIdx-1])
	}
}

func TestPromptPast6LinesScrollsAndHasNoCharLimit(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s"}, nil)
	m.SetSize(60, 30)

	if m.TextArea.CharLimit != 0 {
		t.Fatalf("expected CharLimit to be 0 (unlimited), got %d", m.TextArea.CharLimit)
	}

	altEnter := tea.KeyMsg{Type: tea.KeyEnter, Alt: true}

	// Type 10 lines (exceeds max 6 lines)
	for i := 1; i <= 10; i++ {
		lineText := fmt.Sprintf("line %d with plenty of characters to exceed 400 total chars across all lines", i)
		for _, r := range lineText {
			m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
		}
		_ = m.View()
		if i < 10 {
			m, _ = m.Update(altEnter)
			_ = m.View()
		}
	}

	// Value length is well over 400 chars
	if len(m.TextArea.Value()) <= 400 {
		t.Fatalf("expected prompt value > 400 chars, got %d", len(m.TextArea.Value()))
	}

	// Prompt visual height is capped at max 6 lines
	if m.promptHeight() != 6 {
		t.Fatalf("expected promptHeight capped at 6, got %d", m.promptHeight())
	}

	view := ansi.Strip(m.View())
	lines := strings.Split(view, "\n")
	if len(lines) != 30 {
		t.Fatalf("expected exactly 30 total lines in view, got %d", len(lines))
	}

	// Line 10 (latest line) is visible in the view
	if !strings.Contains(view, "line 10") {
		t.Fatalf("expected line 10 to be visible in scrolled view:\n%s", view)
	}
}

func TestPromptCtrlGAndEditorFinishedMsg(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s"}, nil)
	m.SetSize(60, 25)
	m.TextArea.SetValue("initial prompt text")

	// Pressing Ctrl+G should return a non-nil tea.Cmd
	var cmd tea.Cmd
	m, cmd = m.Update(tea.KeyMsg{Type: tea.KeyCtrlG})
	if cmd == nil {
		t.Fatal("expected non-nil cmd from KeyCtrlG")
	}

	// Create a temp file simulating editor output
	tmp, err := os.CreateTemp("", "test-editor-finished-*.md")
	if err != nil {
		t.Fatal(err)
	}
	newContent := "updated text from external editor\nwith multiple lines\n"
	tmp.WriteString(newContent)
	tmp.Close()

	// Dispatch ChatEditorFinishedMsg
	var finishCmd tea.Cmd
	m, finishCmd = m.Update(ChatEditorFinishedMsg{
		SessionID:  m.SessionID,
		Generation: m.Generation,
		Path:       tmp.Name(),
		Err:        nil,
	})
	if finishCmd == nil {
		t.Fatal("expected non-nil cmd restoring mouse mode after editor finished")
	}
	if finishCmd() != tea.EnableMouseCellMotion() {
		t.Fatalf("expected EnableMouseCellMotion msg from editor finished cmd, got %#v", finishCmd())
	}

	// Verify temp file was removed
	if _, err := os.Stat(tmp.Name()); !os.IsNotExist(err) {
		t.Fatalf("expected temp file to be removed after ChatEditorFinishedMsg, stat err: %v", err)
	}

	// Verify prompt value was updated (trailing newline trimmed)
	expectedVal := strings.TrimRight(newContent, "\r\n")
	if m.TextArea.Value() != expectedVal {
		t.Fatalf("expected TextArea value %q, got %q", expectedVal, m.TextArea.Value())
	}

	// Verify layout synced to 2 lines
	if m.promptHeight() != 2 {
		t.Fatalf("expected promptHeight 2 after editor returned 2 lines, got %d", m.promptHeight())
	}
}


func TestPromptWrappingBoundaryExactMatch(t *testing.T) {
	input := "can you figure out how to make manual triggers from our ci auth properly with WIF? rn it doesnt..."
	for width := 40; width <= 130; width++ {
		m := NewChatModel(&daemon.Session{ID: "s"}, nil)
		height := 25
		m.SetSize(width, height)

		for _, r := range input {
			m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
		}

		view := ansi.Strip(m.View())
		lines := strings.Split(view, "\n")
		if len(lines) != height {
			t.Fatalf("width %d: expected view height %d, got %d", width, height, len(lines))
		}

		// "doesnt..." must never disappear from the view
		if !strings.Contains(view, "doesnt...") {
			t.Fatalf("width %d: prompt text 'doesnt...' was truncated from view:\n%s", width, view)
		}

		// Prompt height must match composerView line count exactly
		cvLines := strings.Split(ansi.Strip(m.composerView()), "\n")
		if len(cvLines) != m.promptHeight() {
			t.Fatalf("width %d: composerView line count %d != promptHeight %d", width, len(cvLines), m.promptHeight())
		}
	}
}

