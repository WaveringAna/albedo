package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	"github.com/charmbracelet/x/ansi"
)

func ms(v int64) *int64 { return &v }

func plainRows(lines []string) []string {
	var rows []string
	for _, row := range lines {
		plain := []rune(strings.TrimRight(ansi.Strip(row), " "))
		rows = append(rows, string(plain[min(railWidth, len(plain)):]))
	}
	return rows
}

func replayTurn(m *ChatModel, start int64, text string) {
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventUser, Text: text, Source: "chat", Timestamp: ms(start)})
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventTool, ToolName: "python", ToolArgs: map[string]any{"code": "x"}})
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventMessage, Text: "answer to " + text, Timestamp: ms(start + 23_000)})
}

func TestTurnSignoffUsesReplayedTimestamps(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s"}, nil)
	m.SetSize(100, 40)
	replayTurn(&m, 1_000_000, "first")
	replayTurn(&m, 1_000_000+2*3600_000, "second")
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventInterrupted})
	rows := plainRows(m.settledLines)
	var signoffs []string
	for _, row := range rows {
		if strings.Contains(row, "tool") && strings.Contains(row, "s ·") || strings.Contains(row, "stopped by you") {
			signoffs = append(signoffs, row)
		}
	}
	if len(signoffs) != 2 || !strings.HasSuffix(signoffs[0], " 23s · 1 tool") || !strings.Contains(signoffs[1], "stopped by you · 23s · 1 tool") {
		t.Fatalf("signoffs %q in:\n%s", signoffs, strings.Join(rows, "\n"))
	}
	if !strings.Contains(strings.Join(rows, "\n"), "you · 1h later") {
		t.Fatalf("second message should note the pause since the first turn ended:\n%s", strings.Join(rows, "\n"))
	}
	for i, row := range rows {
		if row == "answer to first" && rows[i+1] != signoffs[0] {
			t.Fatalf("signoff should hang under the reply it closes:\n%s", strings.Join(rows, "\n"))
		}
	}
}

func TestJumpToYouLandsOnYourMessages(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s"}, nil)
	m.SetSize(100, 20)
	for i := int64(0); i < 4; i++ {
		m.appendSettledEntry(HistoryEntry{Kind: EntryUser, Speaker: "You", Text: "question", Timestamp: 1 + i})
		m.appendSettledEntry(HistoryEntry{Kind: EntryAssistant, Speaker: "albedo", Text: strings.Repeat("line\n", 15), Timestamp: 1 + i})
	}
	m.refreshViewportContent()
	var landed []string
	for range 3 {
		m.jumpToYou(true)
		landed = append(landed, plainRows(strings.Split(m.Viewport.View(), "\n")[:1])[0])
	}
	for _, top := range landed {
		if top != "you" {
			t.Fatalf("jump should put your message at the top, got %q", landed)
		}
	}
	for range 4 {
		m.jumpToYou(false)
	}
	if !m.Follow {
		t.Fatal("jumping forward past your newest message should follow the live transcript")
	}
}

// An idle status poll with nothing live leaves the transcript as it is, and
// one that ends a live tool row settles it.
func TestIdleStatusPollRefreshesOnlyToSettle(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s"}, nil)
	m.SetSize(100, 40)
	idle := daemon.AgentStatus{Idle: true}
	poll := func() {
		m, _ = m.Update(ChatStatusMsg{SessionID: m.SessionID, Generation: m.Generation, Revision: m.statusRevision, Status: &idle})
	}
	m.Viewport.SetContent("untouched")
	poll()
	if !strings.Contains(m.Viewport.View(), "untouched") {
		t.Fatal("an idle poll with nothing live rendered the transcript again")
	}
	m.ToolProgressText = "running python"
	poll()
	if strings.Contains(m.Viewport.View(), "untouched") || m.ToolProgressText != "" {
		t.Fatal("an idle poll should settle the live tool row")
	}
}
