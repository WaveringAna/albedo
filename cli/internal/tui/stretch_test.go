package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"github.com/charmbracelet/x/ansi"
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

// A tick moves the face on by one frame.
func TestEachTickShowsTheNextFace(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s"}, nil)
	m.SetSize(120, 30)
	m.Status.Running = true
	m.reseedMood()
	mood, pool := m.phaseMood(), animations[m.phaseMood()]
	set := pool[mood.pick(m.moodSeed, len(pool))]
	face := func() string {
		for _, row := range strings.Split(ansi.Strip(m.View()), "\n") {
			if _, face, ok := strings.Cut(row, m.statusLine()+" "); ok {
				return strings.TrimSpace(face)
			}
		}
		return ""
	}
	for i := range 2 * len(set) {
		if got, want := face(), set[i%len(set)]; got != want {
			t.Fatalf("tick %d shows %q, want %q", i, got, want)
		}
		m, _ = m.Update(ChatProgressTickMsg{SessionID: m.SessionID, Generation: m.Generation})
	}
}

// The face keeps its tick while a modal covers the chat, so it still moves
// once you come back.
func TestFaceKeepsTickingUnderAModal(t *testing.T) {
	session := daemon.Session{ID: "s1", Model: "model"}
	app := NewAppModel(nil, config.Profiles{}, &session, "/work", false)
	app.Chat.SetSize(80, 22)
	app.Chat.Status.Running = true
	app.Chat.startAnimation()
	app.State = AppStateModelPicker
	updated, cmd := app.Update(ChatProgressTickMsg{SessionID: session.ID, Generation: app.Chat.Generation})
	app = updated.(AppModel)
	if app.Chat.ProgressFrame != 1 || cmd == nil {
		t.Fatal("a tick under a modal should advance the face and schedule the next")
	}
}
