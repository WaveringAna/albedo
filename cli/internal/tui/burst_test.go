package tui

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
	"github.com/charmbracelet/x/ansi"
)

func TestPathGroupsBraceSiblings(t *testing.T) {
	got := pathGroups([]string{"cli/internal/tui/chat.go", "cli/internal/tui/transcript.go", "README.md", "src/a.rs", "src/b.rs", "src/c.gleam", "cli/"})
	want := []string{"tui/{chat,transcript}.go", "{README.md,cli/}", "src/{a.rs,b.rs,c.gleam}"}
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestPathGroupsKeepDistinctParents(t *testing.T) {
	got := pathGroups([]string{"/tmp/a.go", "src/x/main.go", "test/x/main.go", "src/x/extra.go"})
	want := []string{"/tmp/a.go", "src/x/{main,extra}.go", "test/x/main.go"}
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestCommandNameKeepsProgramAndSubcommand(t *testing.T) {
	cases := map[string]string{
		"cd cli && go test ./...":            "go test",
		"git -C cli diff":                    "git",
		"FOO=1 cargo build --release":        "cargo build",
		"/usr/bin/rg -n pattern src":         "rg",
		"python3 test/harness/trace_test.py": "python3",
		"set -e; npm run build":              "npm run",
		"ls | head":                          "ls",
		"grep foo notes.txt":                 "grep",
		"make test":                          "make test",
		"cd cli && \\\n go test ./...":       "go test",
	}
	for command, want := range cases {
		if got := commandName(command); got != want {
			t.Errorf("%q ran %q, want %q", command, got, want)
		}
	}
}

func TestThinkingLineFollowsTheNewestNonemptyLine(t *testing.T) {
	cases := map[string]string{
		"**Reviewing the diff**":               "Reviewing the diff",
		"\n**Reviewing the diff**\n\nthe rest": "the rest",
		"first\n\n> **next part**\r\n \n":      "next part",
		"only one line":                        "only one line",
		"\n\n":                                 "",
	}
	for thought, want := range cases {
		if got := thinkingLine(thought); got != want {
			t.Errorf("%q: got %q, want %q", thought, got, want)
		}
	}
}

func traced(activities []daemon.ToolActivity, changes ...daemon.FileChange) HistoryEntry {
	return HistoryEntry{Kind: EntryTool, ToolName: "python", ToolResult: `{"status":"ok"}`,
		ToolTrace: &daemon.ToolTrace{Activities: activities, Changes: changes}}
}

func burstFixture() []HistoryEntry {
	ws := "/w/albedo/"
	return []HistoryEntry{
		{Kind: EntryThinking, Text: "hm", ElapsedMs: 34_000},
		traced([]daemon.ToolActivity{{Kind: "read", Target: ws + "cli/internal/tui/chat.go"}, {Kind: "read", Target: ws + "cli/internal/tui/transcript.go"}}),
		traced([]daemon.ToolActivity{{Kind: "run", Target: "cd cli && go test ./..."}}),
		traced([]daemon.ToolActivity{{Kind: "run", Target: "go test ./internal/tui"}}),
		traced([]daemon.ToolActivity{{Kind: "read", Target: ws + "priv/python/albedo_trace.py"}},
			daemon.FileChange{Path: ws + "priv/python/albedo_trace.py", Kind: "diff", Added: 5, Removed: 2}),
		{Kind: EntryTool, ToolName: "python", ToolResult: `{"status":"error","error":"boom"}`, ToolArgs: map[string]any{"code": "1/0"}},
	}
}

func TestBurstSummarizesItsWorkOnOneRow(t *testing.T) {
	r := TranscriptRenderer{Workspace: "/w/albedo"}
	rows := strings.Split(ansi.Strip(r.RenderBurst(burstFixture(), DisplayFlags{}, 200)), "\n")
	want := "thought 34s · read tui/{chat,transcript}.go · edited python/albedo_trace.py · ran go test ×2 · python 1/0 · 1 failed  +5 −2"
	if rows[0] != want {
		t.Fatalf("summary\n got %q\nwant %q", rows[0], want)
	}
	if len(rows) != 2 || !strings.Contains(rows[1], "python · 1/0") {
		t.Fatalf("the failed call lost its own row: %q", rows)
	}
	narrow := ansi.Strip(r.RenderBurst(burstFixture(), DisplayFlags{}, 60))
	if first := strings.Split(narrow, "\n")[0]; ansi.StringWidth(first) > 60 || !strings.Contains(first, "read 2 files") || !strings.Contains(first, "1 failed") {
		t.Fatalf("narrow summary should shorten lists but keep failures: %q", first)
	}
}

// A thought this client watched settles with the time it took.
func TestAWatchedThoughtKeepsItsDuration(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s"}, nil)
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventThinking, Text: "hm"})
	if time.Since(m.thinkingSince) > time.Minute {
		t.Fatalf("a live thought's clock did not start: %v", m.thinkingSince)
	}
	m.thinkingSince = m.thinkingSince.Add(-3 * time.Second)
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventThinking, Text: " more"})
	m.settleActiveStream()
	entries := m.History.Entries()
	if len(entries) != 1 || entries[0].ElapsedMs < 3000 || entries[0].ElapsedMs > 60_000 || entries[0].Text != "hm more" {
		t.Fatalf("watched thought lost its duration: %+v", entries)
	}
}

func TestAReplayedThoughtHasNoMadeUpDuration(t *testing.T) {
	r := NewTranscriptRenderer()
	got := ansi.Strip(r.RenderBurst([]HistoryEntry{{Kind: EntryThinking, Text: "hm"}}, DisplayFlags{}, 80))
	if got != "thought" {
		t.Fatalf("got %q", got)
	}
}

// A burst draws live while it grows and settles once, when prose ends it.
func TestBurstSettlesOnceProseEndsIt(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s", Workspace: "/w/albedo"}, nil)
	m.SetSize(120, 40)
	m.appendSettledEntry(HistoryEntry{Kind: EntryUser, Text: "go"})
	settled := len(m.settledLines)
	for _, entry := range burstFixture()[:4] {
		m.appendSettledEntry(entry)
	}
	if len(m.settledLines) != settled {
		t.Fatal("an open burst wrote settled rows")
	}
	m.refreshViewportContent()
	if view := ansi.Strip(m.Viewport.View()); !strings.Contains(view, "ran go test ×2") {
		t.Fatalf("the open burst is not drawn: %q", view)
	}
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventMessage, Text: "done"})
	joined := ansi.Strip(strings.Join(m.settledLines[settled:], "\n"))
	if strings.Count(joined, "ran go test") != 1 || !strings.Contains(joined, "done") ||
		strings.Index(joined, "ran go test") > strings.Index(joined, "done") {
		t.Fatalf("burst did not settle once, before the prose: %q", joined)
	}
	m.rebuildSettledLines()
	if again := ansi.Strip(strings.Join(m.settledLines, "\n")); strings.Count(again, "ran go test") != 1 {
		t.Fatalf("a rebuild drew the burst %d times", strings.Count(again, "ran go test"))
	}
}

// The cached live frame renders exactly what collecting the same entries
// renders, and is rebuilt only when one of the inputs in its key changes:
// each step below mutates exactly one, and the render counter must move once.
func TestCachedBurstMatchesCollectedBurst(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s", Workspace: "/w/albedo"}, nil)
	m.SetSize(120, 30)
	for _, entry := range burstFixture() {
		m.appendSettledEntry(entry)
	}
	m.refreshViewportContent()
	entries := m.History.Entries()
	burst := trailingBurst(entries, m.Flags)
	if len(burst) != len(burstFixture()) {
		t.Fatalf("trailing burst is %d entries, want %d", len(burst), len(burstFixture()))
	}
	want := strings.Join(m.Renderer.BurstBlock(entries[:len(entries)-len(burst)], burst, m.Flags), "\n")
	if got := strings.Join(m.burstRows, "\n"); got != want {
		t.Fatalf("cached frame diverged:\n%s\nwant:\n%s", got, want)
	}

	renders := m.burstRenders
	step := func(name string, mutate func(), want int) {
		mutate()
		m.refreshViewportContent()
		if got := m.burstRenders - renders; got != want {
			t.Fatalf("%s: frame rebuilt %d times, want %d", name, got, want)
		}
		renders = m.burstRenders
	}
	step("idle refresh", func() {}, 0)
	step("a settled entry", func() { m.appendSettledEntry(burstFixture()[0]) }, 1)
	step("width", func() { m.SetSize(100, 30) }, 1)
	// the frame depends on the flags (diffs render the changes), so each flip
	// redraws once; flipping back lands on the cached frame again
	step("flags there and back", func() { m.Flags.Tools = true; m.refreshViewportContent(); m.Flags.Tools = false }, 2)
	step("workspace", func() { m.Renderer.Workspace = "/w/other" }, 1)
	step("reset then the same entries", func() {
		m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventReset})
		for _, entry := range burstFixture() {
			m.appendSettledEntry(entry)
		}
	}, 1)
	// same entry count after a reset, different content: only the epoch tells
	// the cache these are not the entries it rendered
	other := burstFixture()
	other[4].ToolTrace.Changes[0].Path = "/w/albedo/cli/internal/tui/other.go"
	step("reset then same-sized different entries", func() {
		m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventReset})
		for _, entry := range other {
			m.appendSettledEntry(entry)
		}
	}, 1)
	m.SetSize(240, 30) // wide enough that the ran list is not counted away
	m.refreshViewportContent()
	entries = m.History.Entries()
	burst = trailingBurst(entries, m.Flags)
	want = strings.Join(m.Renderer.BurstBlock(entries[:len(entries)-len(burst)], burst, m.Flags), "\n")
	if got := strings.Join(m.burstRows, "\n"); got != want || !strings.Contains(got, "tui/other.go") {
		t.Fatalf("same-sized history after a reset kept the old frame:\n%s\nwant:\n%s", got, want)
	}
	// the same equivalence under the width and workspace the steps left behind
	entries = m.History.Entries()
	burst = trailingBurst(entries, m.Flags)
	want = strings.Join(m.Renderer.BurstBlock(entries[:len(entries)-len(burst)], burst, m.Flags), "\n")
	if strings.Join(m.burstRows, "\n") != want {
		t.Fatalf("after a reset the frame went stale:\n%s\nwant:\n%s", strings.Join(m.burstRows, "\n"), want)
	}
}

// Eviction swaps the head of history without changing its length, so the
// cached frame must key on evictions too or the live burst freezes.
func TestEvictionKeepsTheLiveBurstCurrent(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s", Workspace: "/w"}, nil)
	m.SetSize(120, 30)
	m.History = NewBoundedHistory(4, 1<<20)
	for i := range 8 {
		m.appendSettledEntry(traced([]daemon.ToolActivity{{Kind: "read", Target: fmt.Sprintf("/w/f%d.go", i)}}))
		m.refreshViewportContent()
	}
	rows := strings.Join(m.burstRows, "\n")
	if !strings.Contains(rows, "f7}") || strings.Contains(rows, "f0") || strings.Contains(rows, "f3") {
		t.Fatalf("live burst froze across eviction: %q", rows)
	}
}

// Two recordings of one path (relative and absolute) name to one item, and a
// file that was edited is not also listed as read.
func TestSummaryDedupesAfterNaming(t *testing.T) {
	r := TranscriptRenderer{Workspace: "/w"}
	entries := []HistoryEntry{
		traced([]daemon.ToolActivity{{Kind: "read", Target: "/w/cli/a.go"}, {Kind: "read", Target: "cli/a.go"}}),
		traced([]daemon.ToolActivity{{Kind: "read", Target: "cli/b.go"}},
			daemon.FileChange{Path: "/w/cli/b.go", Kind: "diff", Added: 1}),
	}
	row := ansi.Strip(r.RenderBurst(entries, DisplayFlags{}, 200))
	if strings.Contains(row, "{a,a}.go") || strings.Contains(row, "read 2 files") {
		t.Fatalf("one path named twice: %q", row)
	}
	readClause := row[strings.Index(row, "read "):strings.Index(row, " · edited")]
	if !strings.Contains(readClause, "cli/a.go") || strings.Contains(readClause, "b.go") || strings.Contains(readClause, "{a,a}") {
		t.Fatalf("read list wrong: %q", readClause)
	}
	if !strings.Contains(row, "edited cli/b.go") {
		t.Fatalf("edited list wrong: %q", row)
	}
}
