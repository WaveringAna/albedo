// Transcript re-rendering on width changes, not height changes, prevents
// expensive UI refreshes. The cost is invisible outside the process: the
// rendered text is identical either way, so no e2e can catch a regression.
package tui

import (
	"testing"

	"albedo/cli/internal/daemon"
)

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
