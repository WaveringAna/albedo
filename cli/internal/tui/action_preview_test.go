// Action-row lifetime across streaming, replay, and turn completion is not exercised by daemon E2E.
package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestGroupedActionRowHoldsUntilTheNextAction(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(100, 30)
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventUser, Text: "check it"})
	progress := func(target string) {
		m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventToolProgress,
			Progress: &daemon.ToolProgress{CallID: "progress-" + target, Name: "python", Phase: "running"}})
	}
	finish := func(kind, target string) {
		m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventTool, ToolName: "python",
			ProgressCallID: "progress-" + target,
			ToolResult:     `{"status":"ok"}`, ToolTrace: &daemon.ToolTrace{Activities: []daemon.ToolActivity{
				{Kind: kind, Target: target},
			}}})
	}
	visible := func() string {
		m.refreshViewportContent()
		return ansi.Strip(m.Viewport.View())
	}
	occupied := func() int {
		n := 0
		for row := range strings.SplitSeq(visible(), "\n") {
			if strings.TrimSpace(row) != "" {
				n++
			}
		}
		return n
	}

	progress("first.go")
	finish("read", "first.go")
	if got := visible(); !strings.Contains(got, "read first.go") {
		t.Fatalf("completed read vanished: %q", got)
	}

	progress("go test")
	before := occupied()
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventToolProgress, Progress: nil})
	if got := visible(); strings.Contains(got, "running python") {
		t.Fatalf("clear progress retained the live action row: %q", got)
	}
	finish("run", "go test")
	if got := visible(); !strings.Contains(got, "ran go test") || strings.Contains(got, "running python") || occupied() != before {
		t.Fatalf("result removed the action row or changed its height: %q, before %d after %d", got, before, occupied())
	}

	progress("next.go")
	if got := visible(); !strings.Contains(got, "running python") {
		t.Fatalf("the new action did not replace the last: %q", got)
	}
	finish("read", "next.go")
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventThinking, Text: "**Planning the next step**\nmore thought"})
	thinking := occupied()
	if got := visible(); !strings.Contains(got, "more thought…") || strings.Contains(got, "Planning the next step") || strings.Contains(got, "running python") {
		t.Fatalf("thinking did not replace the tool action with its newest line: %q", got)
	}
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventUsage})
	if got := visible(); !strings.Contains(got, "more thought") || strings.Contains(got, "more thought…") || occupied() != thinking {
		t.Fatalf("finished thought removed its newest line: %q, before %d after %d", got, thinking, occupied())
	}
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventText, Text: "here's why"})
	if got := visible(); strings.Contains(got, "more thought") || !strings.Contains(got, "here's why") {
		t.Fatalf("prose did not replace the thought action: %q", got)
	}
}

func TestChatToolResultKeepsOtherInterleavedProgress(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	callA := &daemon.ToolProgress{CallID: "run:1:0", ToolCallID: "native-a", Name: "python", Phase: "running"}
	callB := &daemon.ToolProgress{CallID: "run:1:1", ToolCallID: "native-b", Name: "python", Phase: "generating", Code: &daemon.ToolCodePreview{Text: "print('b')"}}
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventToolProgress, Progress: callA})
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventToolProgress, Progress: callB})
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventTool, ProgressCallID: callA.CallID, ToolName: "python", ToolResult: "done"})
	m.SetSize(100, 30)
	m.refreshViewportContent()
	if got := ansi.Strip(m.Viewport.View()); !strings.Contains(got, "generating python") || !strings.Contains(got, "print('b')") {
		t.Fatalf("call A's result cleared call B's visible activity: %q", got)
	}
}

func TestFinishedActionDoesNotLeakIntoVerboseOrReplayedHistory(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(100, 30)
	result := daemon.StreamEvent{Type: daemon.EventTool, ToolName: "python",
		ToolArgs: map[string]any{"code": `print("tool_source_sentinel")`}, ToolResult: `{"status":"ok"}`}
	m.handleStreamEvent(result)
	m.refreshViewportContent()
	if got := ansi.Strip(m.Viewport.View()); strings.Count(got, "tool_source_sentinel") != 2 {
		t.Fatalf("compact history and the completed action are not both visible: %q", got)
	}
	m.TextArea.SetValue("/verbose")
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	verboseCount := strings.Count(ansi.Strip(m.Viewport.View()), "tool_source_sentinel")
	if verboseCount == 0 {
		t.Fatal("verbose history hid the tool source")
	}
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventTurnCompleted})
	m.refreshViewportContent()
	if got := ansi.Strip(m.Viewport.View()); strings.Count(got, "tool_source_sentinel") != verboseCount {
		t.Fatalf("the completed preview duplicated the verbose tool row: %q", got)
	}
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventReset})
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventToolProgress, Replayed: true,
		Progress: &daemon.ToolProgress{CallID: "old", Name: "python", Phase: "generating", Code: &daemon.ToolCodePreview{Text: "obsolete_live_sentinel"}}})
	result.Replayed = true
	m.handleStreamEvent(result)
	m.TextArea.SetValue("/verbose")
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if got := ansi.Strip(m.Viewport.View()); strings.Contains(got, "obsolete_live_sentinel") || strings.Count(got, "tool_source_sentinel") != 1 {
		t.Fatalf("replaying old history produced a live action row: %q", got)
	}
}

func TestTurnSignoffReplacesTheLastActionRow(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(100, 30)
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventUser, Text: "do it"})
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventToolProgress,
		Progress: &daemon.ToolProgress{CallID: "progress-1", Name: "python", Phase: "running"}})
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventTool, ToolName: "python",
		ProgressCallID: "progress-1", ToolArgs: map[string]any{"code": "print(42)"}, ToolResult: `{"status":"ok"}`})
	m.refreshViewportContent()
	view := ansi.Strip(m.Viewport.View())
	if strings.Count(view, "python · print(42)") != 1 || !strings.Contains(view, "python print(42)") {
		t.Fatalf("group summary and completed action are not both visible: %q", view)
	}
	status := daemon.AgentStatus{Idle: true}
	m, _ = m.Update(ChatStatusMsg{SessionID: m.SessionID, Generation: m.Generation,
		Revision: m.statusRevision, Status: &status})
	if strings.Contains(ansi.Strip(m.Viewport.View()), "python · print(42)") ||
		!strings.Contains(ansi.Strip(m.Viewport.View()), "python print(42)") {
		t.Fatalf("turn signoff left an action row behind: %q", m.Viewport.View())
	}
}

func TestMetadataEventsKeepVisibleLiveToolActivity(t *testing.T) {
	for _, kind := range []daemon.EventType{daemon.EventUsage, daemon.EventCommitted, daemon.EventTurnMembership, daemon.EventNote, daemon.EventCompacted} {
		t.Run(string(kind), func(t *testing.T) {
			m := newTestChatModel(t, &daemon.Session{ID: "s"})
			m.SetSize(100, 30)
			m.Flags.Tools = true
			m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventToolProgress, Progress: &daemon.ToolProgress{CallID: "active", Name: "python", Phase: "generating", Code: &daemon.ToolCodePreview{Text: "live_code_sentinel"}}})
			m.handleStreamEvent(daemon.StreamEvent{Type: kind})
			m.refreshViewportContent()
			if got := ansi.Strip(m.Viewport.View()); !strings.Contains(got, "live_code_sentinel") || m.statusLine() != "generating call" {
				t.Fatalf("%s removed visible live activity: %q, status %q", kind, got, m.statusLine())
			}
		})
	}
}

func TestIdleSignoffCannotRestoreObsoleteCallAfterNextResult(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(100, 30)
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventToolProgress, Progress: &daemon.ToolProgress{CallID: "old", Name: "obsolete_tool", Phase: "running"}})
	status := daemon.AgentStatus{Idle: true}
	m, _ = m.Update(ChatStatusMsg{SessionID: m.SessionID, Generation: m.Generation, Revision: m.statusRevision, Status: &status})
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventToolProgress, Progress: &daemon.ToolProgress{CallID: "fresh", Name: "python", Phase: "running"}})
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventTool, ProgressCallID: "fresh", ToolName: "python", ToolResult: "done"})
	m.refreshViewportContent()
	if got := ansi.Strip(m.Viewport.View()); strings.Contains(got, "obsolete_tool") || m.statusLine() == "running obsolete_tool" {
		t.Fatalf("idle signoff restored obsolete activity: %q", got)
	}
}

func TestProseTakesActionSlotWithoutForgettingOtherLiveCalls(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(100, 30)
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventToolProgress, Progress: &daemon.ToolProgress{CallID: "a", Name: "still_running", Phase: "running"}})
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventText, Text: "working on it"})
	m.refreshViewportContent()
	if got := ansi.Strip(m.Viewport.View()); !strings.Contains(got, "working on it") || strings.Contains(got, "running still_running") {
		t.Fatalf("prose did not take the action slot: %q", got)
	}
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventToolProgress, Progress: &daemon.ToolProgress{CallID: "b", Name: "python", Phase: "running"}})
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventTool, ProgressCallID: "b", ToolName: "python", ToolResult: "done"})
	m.refreshViewportContent()
	if got := ansi.Strip(m.Viewport.View()); !strings.Contains(got, "running still_running") {
		t.Fatalf("prose forgot call A before call B's result: %q", got)
	}
}
