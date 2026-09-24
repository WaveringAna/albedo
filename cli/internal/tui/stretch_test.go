package tui

import (
	"testing"

	"albedo/cli/internal/daemon"
)

// Each tool call and each thinking spell draws its animation again, and one
// call keeps its animation from generating through running.
func TestEveryToolCallAndThoughtDrawsAgain(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s"}, nil)
	call := func(id, phase string) {
		m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventToolProgress, Progress: &daemon.ToolProgress{CallID: id, Name: "python", Phase: phase}})
	}
	for i := range 20 {
		id := string(rune('a' + i))
		call(id, "generating")
		seed := m.moodSeed
		call(id, "running")
		if m.moodSeed != seed {
			t.Fatal("one tool call changed its animation between generating and running")
		}
		call(id+"'", "generating")
		if m.moodSeed == seed {
			t.Fatal("the next tool call should draw again")
		}
		m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventTool, ToolName: "python"})
		thought := m.moodSeed
		m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventThinking, Text: "hm"})
		if m.phaseMood() != moodThinking || m.moodSeed == thought {
			t.Fatal("a thinking spell after a tool call should draw a new animation")
		}
	}
}
