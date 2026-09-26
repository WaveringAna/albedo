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

// A message you send shows at once as a greyed-out copy where it will
// settle, not as a "sending" row under the transcript.
func TestPendingMessageIsAGreyedOutCopyInTheTranscript(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s"}, nil)
	m.Client = daemon.NewChatClient(daemon.ChatClientOptions{BaseURL: "http://127.0.0.1:1", AgentID: "s"})
	m.SetSize(80, 30)
	m.appendSettledEntry(HistoryEntry{Kind: EntryAssistant, Speaker: "albedo", Text: "ready", Timestamp: time.Now().UnixMilli() - 1000})
	var cmds []tea.Cmd
	m.submitInput("hello there", &cmds)

	view := ansi.Strip(m.View())
	if strings.Contains(view, "sending") || !strings.Contains(ansi.Strip(m.Viewport.View()), "│ hello there") {
		t.Fatalf("the message should be in the transcript, not in a sending row:\n%s", view)
	}
	rows := m.pendingRows()
	if len(rows) != 3 || strings.TrimSpace(ansi.Strip(rows[1])) != "│ you" || strings.TrimSpace(ansi.Strip(rows[2])) != "│ hello there" {
		t.Fatalf("pending rows: %q", plainRows(rows))
	}

	// the echo replaces the copy in place
	pendingView := strings.TrimRight(ansi.Strip(m.Viewport.View()), " \n")
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventUser, Source: "chat", Text: "hello there", ClientID: m.Client.ClientID()})
	m.refreshViewportContent()
	if len(m.pendingUsers) != 0 || len(m.pendingRows()) != 0 {
		t.Fatal("the echo should settle the pending copy")
	}
	settled := strings.TrimRight(ansi.Strip(m.Viewport.View()), " \n")
	if settled != pendingView {
		t.Fatalf("settling moved the transcript:\n%s", settled)
	}
}

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
