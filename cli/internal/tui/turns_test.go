// Jump-to-user keyboard navigation is interactive viewport state; headless daemon E2E has no PTY to drive shift+up/down.
package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	"github.com/charmbracelet/x/ansi"
)

func plainRows(lines []string) []string {
	var rows []string
	for _, row := range lines {
		plain := []rune(strings.TrimRight(ansi.Strip(row), " "))
		rows = append(rows, string(plain[min(railWidth, len(plain)):]))
	}
	return rows
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
