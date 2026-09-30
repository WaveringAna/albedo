// Scroll follow and reading position across streaming, truncation, and thinking are TUI-only state.
package tui

import (
	"fmt"
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func newTestChatModel(t *testing.T, session *daemon.Session) ChatModel {
	t.Helper()
	conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, "")
	client := daemon.NewChatClient(conn, session.ID)
	model := NewChatModel(session, client)
	t.Cleanup(model.Close)
	return model
}

func TestScrollDoesNotResumeFollowBeforeEndOfLiveOutput(t *testing.T) {
	for _, down := range []struct {
		name string
		msg  tea.Msg
		step int
	}{
		{"arrow", tea.KeyPressMsg{Code: tea.KeyDown}, 1},
		{"page", tea.KeyPressMsg{Code: tea.KeyPgDown}, 13},
		{"wheel", tea.MouseWheelMsg{Button: tea.MouseWheelDown}, 3},
	} {
		t.Run(down.name, func(t *testing.T) {
			m := newTestChatModel(t, &daemon.Session{ID: "s"})
			m.SetSize(80, 20)
			m.appendSettledEntry(HistoryEntry{Kind: EntryAssistant, Text: strings.Repeat("settled\n", 25)})
			m.transcript.activeKind = StreamKindText
			m.transcript.activeText = strings.Repeat("live\n", 55)
			m.refreshViewportContent()
			bottom := m.scrollOffset
			// This is beyond the end of settled lines, but far from the end of live output.
			m.Follow = false
			m.scrollOffset = len(m.settledLines)
			m.refreshViewportContent()
			before := m.scrollOffset
			m, _ = m.Update(down.msg)
			if m.Follow || m.scrollOffset != before+down.step || m.scrollOffset >= bottom {
				t.Fatalf("jumped to tail: before=%d after=%d bottom=%d follow=%v", before, m.scrollOffset, bottom, m.Follow)
			}
			m.refreshViewportContent()
			if m.scrollOffset != before+down.step {
				t.Fatal("next refresh lost scroll position")
			}
			m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyUp})
			if m.scrollOffset != before+down.step-1 || m.Follow {
				t.Fatalf("up did not move one row: offset=%d follow=%v", m.scrollOffset, m.Follow)
			}
			m.scrollBy(1000)
			if !m.Follow || m.scrollOffset != bottom {
				t.Fatalf("tail not restored at actual end: offset=%d bottom=%d", m.scrollOffset, bottom)
			}
		})
	}
}

func TestReadingPositionSurvivesIncomingTranscript(t *testing.T) {
	for _, scroll := range []struct {
		name string
		msg  tea.Msg
	}{
		{"keyboard", tea.KeyPressMsg{Code: tea.KeyPgUp}},
		{"wheel", tea.MouseWheelMsg{Button: tea.MouseWheelUp}},
	} {
		t.Run(scroll.name, func(t *testing.T) {
			m := newTestChatModel(t, &daemon.Session{ID: "s"})
			m.SetSize(80, 20)
			var text strings.Builder
			for i := 0; i < MaxSettledLines+50; i++ {
				fmt.Fprintf(&text, "row %d\n", i)
			}
			m.appendSettledEntry(HistoryEntry{Kind: EntryAssistant, Text: text.String()})
			m.refreshViewportContent()
			m, _ = m.Update(scroll.msg)
			if m.Follow {
				t.Fatal("scrolling up did not pause following")
			}
			before := m.scrollOffset
			visible := strings.Split(ansi.Strip(m.Viewport.View()), "\n")[0]
			m.AddNotice("new activity")
			m, _ = m.Update(ChatStreamEventMsg{SessionID: m.SessionID, Generation: m.Generation, Event: daemon.StreamEvent{Type: daemon.EventNote, Text: "a new line"}})
			if m.Follow || strings.Split(ansi.Strip(m.Viewport.View()), "\n")[0] != visible {
				t.Fatalf("reading position changed: offset %d -> %d, follow=%v", before, m.scrollOffset, m.Follow)
			}
		})
	}
}

// A collapsed thought follows its newest line and keeps it after settling,
// until the next action replaces it; earlier lines stay hidden.
func TestFragmentedThinkingStaysCollapsed(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 20)
	for _, step := range []struct{ text, want, hidden string }{
		{"**Preparing resize/status tests**", "Preparing resize/status tests…", "Verifying"},
		{"\n", "Preparing resize/status tests…", "Verifying"},
		{"**Verifying scroll", "Verifying scroll…", "Preparing"},
		{" behavior**\n\n", "Verifying scroll behavior…", "Preparing"},
	} {
		m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventThinking, Text: step.text})
		m.refreshViewportContent()
		visible := ansi.Strip(m.Viewport.View())
		if !strings.Contains(visible, step.want) || strings.Contains(visible, step.hidden) || strings.Contains(visible, "**") {
			t.Fatalf("thought did not follow its newest line: %q", visible)
		}
	}
	m.settleActiveStream()
	m.refreshViewportContent()
	if visible := ansi.Strip(m.Viewport.View()); !strings.Contains(visible, "Verifying scroll behavior") || strings.Contains(visible, "Preparing") || strings.Contains(visible, "**") || !strings.Contains(visible, "thought") {
		t.Fatalf("settled thought lost its latest line: %q", visible)
	}
}

func TestInterleavedEmptyTextDoesNotSettleThinking(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 20)
	parts := []string{"First thinking token", " second thinking token", " third thinking token"}
	for _, part := range parts {
		m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventThinking, Text: part})
		m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventText, Text: ""})
	}
	m.settleActiveStream()
	entries := m.History.Entries()
	if len(entries) != 1 {
		t.Fatalf("expected 1 settled thinking entry, got %d entries: %+v", len(entries), entries)
	}
	if entries[0].Kind != EntryThinking {
		t.Fatalf("expected EntryThinking, got %v", entries[0].Kind)
	}
	want := "First thinking token second thinking token third thinking token"
	if entries[0].Text != want {
		t.Fatalf("expected %q, got %q", want, entries[0].Text)
	}
}

func TestCompactTranscriptEntries(t *testing.T) {
	r := NewTranscriptRenderer()
	flags := DisplayFlags{}
	thinking := HistoryEntry{Kind: EntryThinking, Text: "Inspecting the repository\n" + strings.Repeat("details ", 30)}
	tool := HistoryEntry{Kind: EntryTool, ToolName: "python", ToolArgs: map[string]any{"code": "print(1)"}, ToolResult: `{"output": "` + strings.Repeat("large ", 200) + `"}`}
	for _, width := range []int{20, 80} {
		for _, entry := range []HistoryEntry{thinking, tool} {
			compact := r.RenderEntry(entry, flags, width)
			if strings.Contains(compact, "\n") || ansi.StringWidth(compact) > width {
				t.Fatalf("not one bounded row at %d: %q", width, compact)
			}
		}
	}
	if strings.Contains(r.RenderEntry(thinking, flags, 80), "Inspecting") {
		t.Fatal("collapsed thinking exposed body text")
	}
	if !strings.Contains(r.RenderEntry(thinking, DisplayFlags{Thinking: true}, 80), "details") {
		t.Fatal("thinking cannot be expanded")
	}
	styled := r.RenderEntry(HistoryEntry{Kind: EntryThinking, Text: "**Verifying scroll behavior**"}, DisplayFlags{Thinking: true}, 80)
	if !strings.Contains(styled, "Verifying scroll behavior") || strings.Contains(styled, "\x1b[1m") {
		t.Fatalf("expanded thinking escaped faint styling: %q", styled)
	}
	if !strings.Contains(r.RenderEntry(tool, DisplayFlags{Tools: true}, 80), "large") {
		t.Fatal("tool output cannot be expanded")
	}
	tool.ToolResult = `{"status":"ok","output":"error: found in source\nTraceback (most recent call last): example","value":"","truncated":false}`
	if summary := r.RenderEntry(tool, flags, 80); strings.Contains(summary, "failed") || strings.Contains(summary, "\n") {
		t.Fatalf("successful Python cell mislabelled as failure: %q", summary)
	}
	failed := tool
	failed.ToolResult = `{"status":"error","output":"trace","value":""}`
	collapsed := r.RenderEntry(failed, flags, 80)
	if strings.Contains(collapsed, "\n") || !strings.Contains(collapsed, "failed") {
		t.Fatalf("failure should remain visible without flooding transcript: %q", collapsed)
	}
}

func TestReadingPositionSurvivesOutputPastTheLineCap(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 20)
	block := func(name string) HistoryEntry {
		return HistoryEntry{Kind: EntryAssistant, Text: name + "\n" + strings.Repeat("line\n", 15)}
	}
	for i := range 60 {
		m.appendSettledEntry(block(fmt.Sprintf("block %d", i)))
	}
	m.Follow = false
	m.scrollOffset = len(m.settledLines) / 2
	m.refreshViewportContent()
	view, offset := m.Viewport.View(), m.scrollOffset
	// Enough output to trim everything above the reading row at the normal cap.
	for i := range 40 {
		m.appendSettledEntry(block(fmt.Sprintf("new %d", i)))
		m.refreshViewportContent()
		if m.Viewport.View() != view || m.scrollOffset != offset {
			t.Fatalf("after %d blocks the view moved: offset %d → %d", i+1, offset, m.scrollOffset)
		}
	}
	m.SetSize(80, 20)
	if m.Viewport.View() != view {
		t.Fatal("re-rendering moved the reading position")
	}
	m.scrollBy(1 << 20)
	m.appendSettledEntry(block("tail"))
	if !m.Follow || len(m.settledLines) > MaxSettledLines {
		t.Fatalf("caps not restored when following: follow=%v lines=%d", m.Follow, len(m.settledLines))
	}
}
