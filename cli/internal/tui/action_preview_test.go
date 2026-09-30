// Action-row lifetime across streaming, replay, and turn completion is not exercised by daemon E2E.
package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	"github.com/charmbracelet/x/ansi"
)

func TestGroupedActionRowHoldsUntilTheNextAction(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(100, 30)
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventUser, Text: "check it"})
	progress := func(kind, target string) {
		m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventToolProgress,
			Progress: &daemon.ToolProgress{Name: "python", Phase: "running",
				Intent: &daemon.ToolIntent{Kind: kind, Target: target}}})
	}
	finish := func(kind, target string) {
		m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventTool, ToolName: "python",
			ToolResult: `{"status":"ok"}`, ToolTrace: &daemon.ToolTrace{Activities: []daemon.ToolActivity{
				{Kind: kind, Target: target},
			}}})
	}
	visible := func() string {
		m.refreshViewportContent()
		return ansi.Strip(m.Viewport.View())
	}
	occupied := func() int {
		n := 0
		for _, row := range strings.Split(visible(), "\n") {
			if strings.TrimSpace(row) != "" {
				n++
			}
		}
		return n
	}

	progress("read", "first.go")
	finish("read", "first.go")
	if got := visible(); !strings.Contains(got, "read first.go") {
		t.Fatalf("completed read vanished: %q", got)
	}

	progress("run", "go test")
	before := occupied()
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventToolProgress})
	if got := visible(); !strings.Contains(got, "running go test") || occupied() != before {
		t.Fatalf("progress cleared before the result: %q", got)
	}
	finish("run", "go test")
	if got := visible(); !strings.Contains(got, "ran go test") || strings.Contains(got, "running go test") || occupied() != before {
		t.Fatalf("result removed the action row or changed its height: %q, before %d after %d", got, before, occupied())
	}

	progress("read", "next.go")
	if got := visible(); !strings.Contains(got, "reading next.go") || strings.Contains(got, "running go test") {
		t.Fatalf("the new action did not replace the last: %q", got)
	}
	finish("read", "next.go")
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventThinking, Text: "**Planning the next step**\nmore thought"})
	thinking := occupied()
	if got := visible(); !strings.Contains(got, "more thought…") || strings.Contains(got, "Planning the next step") || strings.Contains(got, "reading next.go") {
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

func TestFinishedActionDoesNotLeakIntoVerboseOrReplayedHistory(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(100, 30)
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventTool, ToolName: "python", ToolResult: `{"status":"ok"}`})
	if m.ToolProgressText == "" {
		t.Fatal("no completed tool preview")
	}
	m.Flags.Tools = true
	m.refreshViewportContent()
	if strings.Contains(ansi.Strip(m.Viewport.View()), "used python") {
		t.Fatal("the completed preview duplicated the verbose tool row")
	}
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventReset})
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventToolProgress, Replayed: true,
		Progress: &daemon.ToolProgress{Name: "python", Phase: "running"}})
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventTool, ToolName: "python", Replayed: true})
	if m.ToolProgressText != "" || m.ThoughtProgressText != "" {
		t.Fatal("replaying old history produced a live action row")
	}
}

func TestTurnSignoffReplacesTheLastActionRow(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(100, 30)
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventUser, Text: "do it"})
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventToolProgress,
		Progress: &daemon.ToolProgress{Name: "python", Phase: "running"}})
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventTool, ToolName: "python",
		ToolArgs: map[string]any{"code": "print(42)"}, ToolResult: `{"status":"ok"}`})
	m.refreshViewportContent()
	view := ansi.Strip(m.Viewport.View())
	if strings.Count(view, "python · print(42)") != 1 || !strings.Contains(view, "python print(42)") {
		t.Fatalf("group summary and completed action are not both visible: %q", view)
	}
	status := daemon.AgentStatus{Idle: true}
	m, _ = m.Update(ChatStatusMsg{SessionID: m.SessionID, Generation: m.Generation,
		Revision: m.statusRevision, Status: &status})
	if m.ToolProgressText != "" || strings.Contains(ansi.Strip(m.Viewport.View()), "python · print(42)") ||
		!strings.Contains(ansi.Strip(m.Viewport.View()), "python print(42)") {
		t.Fatalf("turn signoff left an action row behind: %q", m.Viewport.View())
	}
}
