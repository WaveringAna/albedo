package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	"github.com/charmbracelet/x/ansi"
)

func TestWorkGlanceShowsStableItemIDBesidePendingCount(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s"}, nil)
	m.SetSize(140, 24)
	m.Glances = []PageGlance{{Title: "pending work", Rows: []PageRow{{ID: "11", Text: "Refactor session", Tone: TonePlain}}}}
	glance := ansi.Strip(m.renderGlances())
	if !strings.Contains(glance, "pending work · 1") || !strings.Contains(glance, "○ #11 Refactor session") {
		t.Fatalf("glance count should not be confused with item ID: %q", glance)
	}
}

// The glance poll and chrome changes resize the chat without changing its body
// width, and must not render the whole transcript again.
func TestResizeRendersTranscriptOnlyForNewBodyWidth(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s"}, nil)
	m.SetSize(140, 24)
	m.appendSettledEntry(HistoryEntry{Kind: EntryAssistant, Speaker: "albedo", Text: "hello"})
	const kept = "rendered once"
	m.settledLines[0] = kept

	m.Glances = []PageGlance{{Title: "pending work", Rows: []PageRow{{ID: "1", Text: "x"}}}}
	m.SetSize(140, 30)
	if m.settledLines[0] != kept {
		t.Fatal("a resize keeping the body width rendered the transcript again")
	}
	m.SetSize(80, 30)
	if m.settledLines[0] == kept {
		t.Fatal("a narrower body should render the transcript again")
	}
}
