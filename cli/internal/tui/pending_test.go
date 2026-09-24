package tui

import (
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
)

// A message you send shows at once as a greyed-out copy where it will
// settle, not as a "sending" row under the transcript.
func TestPendingMessageIsAGreyedOutCopyInTheTranscript(t *testing.T) {
	lipgloss.SetColorProfile(termenv.ANSI256)
	t.Cleanup(func() { lipgloss.SetColorProfile(termenv.Ascii) })
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
