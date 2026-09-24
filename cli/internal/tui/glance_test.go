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
