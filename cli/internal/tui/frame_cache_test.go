// The frame cache is invisible from outside the process: a cached frame and a
// from-scratch one must be the same bytes, and no daemon run can show the
// difference. These tests drive a scripted session through both paths.
package tui

import (
	"fmt"
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// line2 is rows[i], or a marker past the end.
func line2(rows []string, i int) string {
	if i < len(rows) {
		return rows[i]
	}
	return "<missing>"
}

// firstDifference names the first row two frames disagree on.
func firstDifference(got, want string) string {
	gotRows, wantRows := strings.Split(got, "\n"), strings.Split(want, "\n")
	for i := range max(len(gotRows), len(wantRows)) {
		line := func(rows []string) string {
			if i < len(rows) {
				return rows[i]
			}
			return "<missing>"
		}
		if line(gotRows) != line(wantRows) {
			context := ""
			for j := max(0, i-2); j < min(i+3, max(len(gotRows), len(wantRows))); j++ {
				marker := " "
				if j == i {
					marker = ">"
				}
				context += fmt.Sprintf("\n%s cached  %q\n%s scratch %q", marker, line2(gotRows, j), marker, line2(wantRows, j))
			}
			return fmt.Sprintf("\nrow %d:%s", i, context)
		}
	}
	return "\n(the rows agree; the fast path returned a stale string)"
}

// fromScratch renders m with an empty frame cache.
func fromScratch(m ChatModel) string {
	m.frame = nil
	return m.View()
}

// TestCachedFrameMatchesFromScratch replays the messages a session sends and
// checks every frame against the same model drawn without its cache.
func TestCachedFrameMatchesFromScratch(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s", Workspace: "/Users/dawn/proj/albedo", Model: "claude-opus-5-5", Provider: "claude"})
	m.Glances = []PageGlance{
		{Title: "active work", Rows: []PageRow{{ID: "7", Text: "fix the parser", Tone: ToneActive}}},
		{Title: "scheduled", Rows: []PageRow{{Text: "heartbeat: check the gate", Tone: ToneMuted}}},
	}
	m.SetSize(200, 50)
	m.appendSettledEntry(HistoryEntry{Kind: EntryUser, Speaker: "You", Text: "hello there", Timestamp: 1})
	m.appendSettledEntry(HistoryEntry{Kind: EntryAssistant, Speaker: "albedo", Text: "a reply with **strong** words\n\n```go\nfunc x() {}\n```", Timestamp: 2})
	m.appendSettledEntry(HistoryEntry{Kind: EntryTurnEnd, Mood: moodDone, ElapsedMs: 1200, Timestamp: 3})

	check := func(step string) {
		t.Helper()
		got, want := m.View(), fromScratch(m)
		if got != want {
			t.Fatalf("%s: the cached frame differs from a from-scratch one%s", step, firstDifference(got, want))
		}
	}

	check("settled transcript")
	check("unchanged")

	// typing in the composer, a keystroke at a time
	for _, r := range "a draft" {
		m, _ = m.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
		check(fmt.Sprintf("typing %q", r))
	}
	m.TextArea.SetValue("")
	check("cleared draft")

	// a command menu opens on the draft
	m.TextArea.SetValue("/")
	m, _ = m.Update(tea.KeyPressMsg{Code: '/', Text: "/"})
	check("command menu")

	// streaming: text deltas, then the turn's status, then the commit
	for i := range 4 {
		m, _ = m.Update(ChatStreamEventMsg{SessionID: m.SessionID, Generation: m.Generation, Event: daemon.StreamEvent{
			Type: daemon.EventText, MessageID: "live", Text: fmt.Sprintf("token %d ", i),
		}})
		check("streaming")
	}
	m, _ = m.Update(ChatStatusMsg{SessionID: m.SessionID, Generation: m.Generation, Revision: m.statusRevision, Status: &daemon.AgentStatus{Running: true, Phase: &phaseReasoning}, Glances: m.Glances})
	check("running status")
	m, _ = m.Update(ChatStatusMsg{SessionID: m.SessionID, Generation: m.Generation, Revision: m.statusRevision, Status: &daemon.AgentStatus{Idle: true}, Glances: m.Glances})
	check("idle status")

	// the sidebar changes under a frame that did not
	m.Glances[0].Rows[0].Text = "fix the parser, again"
	m.Glances = append(m.Glances, PageGlance{Title: "kernel", Rows: []PageRow{{Text: "gate: running", Tone: ToneWarning}}})
	check("glances changed")
	m.Glances[0].Rows[0].Tone = ToneMuted
	check("glance tone changed")

	// a notice takes a row from the transcript
	m.AddNotice("something happened")
	check("notice")
	m.ClearNotices()
	check("notice cleared")

	// scrolling, then following again
	m.scrollBy(-5)
	check("scrolled up")
	m.scrollBy(1000)
	check("following again")

	// a resize re-wraps everything
	m.SetSize(120, 40)
	check("narrower")
	m.SetSize(200, 50)
	check("wider")

	// the selection is drawn over the rows and is never cached
	anchor, head := Point{Row: 2, Col: 0}, Point{Row: 6, Col: 4}
	m.dragAnchor, m.dragHead = &anchor, head
	check("dragging")
	m.dragAnchor = nil
	check("drag released")

	// a copy status outranks the status line, and the footer's stat moves
	m.CopyStatus = "copied 12 rows"
	check("copy status")
	m.CopyStatus = ""
	prompt, cached := 120000, 100000
	m.Usage = &daemon.Usage{PromptTokens: &prompt, CachedPromptTokens: &cached, Model: "claude-opus-5-5"}
	check("usage")

	// verbose flags re-render transcript rows
	m.Flags = DisplayFlags{Thinking: true, Tools: true}
	check("verbose")
	m.Flags = DisplayFlags{}
	check("terse again")

	// the effort selector replaces the composer with its own rows
	m.effortOptions = []string{"low", "high"}
	check("effort selector")
	m.effortOptions = nil
	check("composer again")
}

// TestFrameCacheReusesPieces checks that a frame which changed nothing reuses
// the body and the input block, and that a change reaches them.
func TestFrameCacheReusesPieces(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.Glances = []PageGlance{{Title: "active work", Rows: []PageRow{{ID: "7", Text: "fix the parser", Tone: ToneActive}}}}
	m.SetSize(200, 24)
	for i := range 3 {
		m.appendSettledEntry(HistoryEntry{Kind: EntryAssistant, Speaker: "albedo", Text: strings.Repeat(fmt.Sprintf("settled prose %d. ", i), 40), Timestamp: int64(i + 1)})
	}
	m.refreshViewportContent()
	if m.scrollLimit == 0 {
		t.Fatalf("the transcript does not scroll: %d rows in a %d-row viewport", len(m.frameLines), m.Viewport.Height())
	}
	_ = m.View()
	if !m.frame.bodyReady || !m.frame.composerReady || m.frame.content == "" {
		t.Fatal("the first frame cached nothing")
	}
	body, composer, content := &m.frame.body[0], &m.frame.composer[0], m.frame.content
	// an unchanged frame returns the string it returned last time
	if second := m.View(); second != content {
		t.Fatal("an unchanged frame rebuilt its content")
	}
	if &m.frame.body[0] != body || &m.frame.composer[0] != composer {
		t.Fatal("an unchanged frame re-rendered the body or the input block")
	}
	// the face is not cached: a tick that moves it must reach the frame
	m.ProgressFrame = 3
	m.Status.Running = true
	_ = m.View()
	if &m.frame.body[0] != body {
		t.Fatal("a status tick re-rendered the transcript body")
	}
	// a scrolled transcript must not reuse the old body
	before := m.scrollOffset
	m.scrollBy(-3)
	_ = m.View()
	if &m.frame.body[0] == body {
		t.Fatalf("a scrolled transcript reused the old body: offset %d -> %d, limit %d, %d rows", before, m.scrollOffset, m.scrollLimit, len(m.frame.body))
	}
}

// TestSidebarCacheFollowsItsInputs checks the glance column is re-rendered when
// and only when what it draws changed.
func TestSidebarCacheFollowsItsInputs(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.Glances = []PageGlance{{Title: "active work", Rows: []PageRow{{ID: "7", Text: "fix the parser", Tone: ToneActive}}}}
	m.SetSize(200, 50)
	_ = m.View()
	if !m.frame.sidebarReady {
		t.Fatal("the first frame cached no sidebar")
	}
	column := &m.frame.sidebar.column[0]
	m.Glances = []PageGlance{{Title: "active work", Rows: []PageRow{{ID: "7", Text: "fix the parser", Tone: ToneActive}}}}
	_ = m.View()
	if &m.frame.sidebar.column[0] != column {
		t.Fatal("equal glances re-rendered the column")
	}
	m.Glances[0].Rows[0].Text = "a different thing"
	if view := m.View(); !strings.Contains(ansi.Strip(view), "a different thing") {
		t.Fatalf("a changed glance did not reach the sidebar:\n%s", ansi.Strip(view))
	}
}

// TestComposerCacheFollowsTheTextarea checks a message that moves the caret
// inside the same value still redraws the input block.
func TestComposerCacheFollowsTheTextarea(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(200, 50)
	m.TextArea.SetValue("hello")
	_ = m.View()
	before := m.View()
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyLeft})
	if after := m.View(); after == before {
		t.Fatal("moving the caret did not redraw the input block")
	}
	if !strings.Contains(ansi.Strip(m.View()), "hello") {
		t.Fatal("the draft vanished from the composer")
	}
}
