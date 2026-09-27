// Queued and failed continue events must not corrupt the TUI transcript.
package tui

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestDotContinueDoesNotAppearInUI(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s"}, nil)
	m.Client = daemon.NewChatClient(daemon.ChatClientOptions{BaseURL: "http://127.0.0.1:1", AgentID: "s"})
	m.SetSize(80, 30)
	m.appendSettledEntry(HistoryEntry{Kind: EntryAssistant, Speaker: "albedo", Text: "ready", Timestamp: time.Now().UnixMilli() - 1000})

	var cmds []tea.Cmd
	m.submitInput(".", &cmds)

	if len(m.pendingUsers) != 0 {
		t.Fatalf("expected 0 pending users for dot continue, got %d", len(m.pendingUsers))
	}
	if len(m.pendingRows()) != 0 {
		t.Fatalf("expected 0 pending rows for dot continue, got %d", len(m.pendingRows()))
	}
	afterView := ansi.Strip(m.Viewport.View())
	if strings.Contains(afterView, "│ .") || strings.Contains(afterView, "│ continue") || strings.Contains(afterView, "│ you") {
		t.Fatalf("transcript should not contain dot or continue prompt:\n%s", afterView)
	}
	if !m.isSending {
		t.Fatal("expected isSending to be true")
	}
	if len(cmds) == 0 {
		t.Fatal("expected cmds to be returned for continue submission")
	}
}

func TestDotContinueErrorDoesNotCorruptPendingUsers(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s"}, nil)
	m.pendingUsers = []PendingUserTurn{{Text: "real user prompt", At: time.Now().UnixMilli()}}
	m.TextArea.SetValue("")

	errMsg := ChatTurnSentMsg{
		SessionID:  "s",
		Generation: m.Generation,
		Prompt:     ".",
		Continue:   true,
		Err:        fmt.Errorf("network failure"),
	}

	um, _ := m.Update(errMsg)

	if len(um.pendingUsers) != 1 || um.pendingUsers[0].Text != "real user prompt" {
		t.Fatalf("pending user turn was corrupted or popped: %+v", um.pendingUsers)
	}
	if um.TextArea.Value() == "." {
		t.Fatalf("text area was overwritten with dot: %q", um.TextArea.Value())
	}
}
