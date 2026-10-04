// Transcript re-rendering on width changes, not height changes, prevents
// expensive UI refreshes. The cost is invisible outside the process: the
// rendered text is identical either way, so no e2e can catch a regression.
// The sidebar's stacking is checked here too: a daemon run would need a live
// job and an active work item at once to show both sections.
package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/daemon/protocol"

	"github.com/charmbracelet/x/ansi"
)

func TestResizeRendersTranscriptOnlyForNewBodyWidth(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
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

func TestSidebarStacksActiveWorkAboveBackgroundJobs(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.Glances = []PageGlance{{Title: "active work", Rows: []PageRow{{ID: "7", Text: "fix the parser", Tone: ToneActive}}}}
	m.Status.RunningJobs = []protocol.KernelJob{{ID: "job1", Command: "go test ./..."}, {ID: "job2", Command: "python3 -c '\nimport os\nprint(1)\n'"}}
	m.SetSize(160, 30)
	view := ansi.Strip(m.View())
	work, jobs := strings.Index(view, "active work"), strings.Index(view, "background jobs")
	if work < 0 || jobs < work || !strings.Contains(view, "fix the parser") || !strings.Contains(view, "go test ./...") {
		t.Fatalf("the sidebar must show active work, then background jobs:\n%s", view)
	}
	if strings.Contains(view, "job1") {
		t.Fatalf("a background job shows its command, not its id:\n%s", view)
	}
	if counts := m.glanceCounts(); len(counts) != 0 {
		t.Fatalf("the footer repeats sections the sidebar shows: %v", counts)
	}
	if !strings.Contains(view, "python3 -c ' import os") {
		t.Fatalf("a multi-line command must fold onto its row:\n%s", view)
	}
	m.Glances, m.Status.RunningJobs = nil, m.Status.RunningJobs[1:]
	m.Status.KernelJobs = new(int64(1))
	m.SetSize(60, 20)
	for line := range strings.SplitSeq(ansi.Strip(m.View()), "\n") {
		if strings.Contains(line, "import os") && !strings.Contains(line, "background job running") {
			t.Fatalf("the status line wrapped a job's command:\n%s", ansi.Strip(m.View()))
		}
		if ansi.StringWidth(line) > 60 {
			t.Fatalf("a %d-cell line at width 60: %q", ansi.StringWidth(line), line)
		}
	}
}
