package tui

import (
	"testing"

	"albedo/cli/internal/daemon"
)

// Opening a session replays its transcript. The replay is history, so it
// must not claim albedo is thinking; only /status and live events say that.
func TestReplayedSnapshotLeavesTheStatusAlone(t *testing.T) {
	m := NewChatModel(&daemon.Session{ID: "s"}, nil)
	m.SetSize(80, 30)
	send := func(e daemon.StreamEvent) {
		next, _ := m.Update(ChatStreamEventMsg{SessionID: m.SessionID, Generation: m.Generation, Event: e})
		m = next
	}
	revision := m.statusRevision
	send(daemon.StreamEvent{Type: daemon.EventReset})
	send(daemon.StreamEvent{Type: daemon.EventUser, Source: "chat", Text: "hi", Replayed: true})
	send(daemon.StreamEvent{Type: daemon.EventThinking, Text: "hmm", Replayed: true})
	if m.Status.Running || m.statusLine() == "thinking" {
		t.Fatalf("a replayed thought marked the session running: %+v, %q", m.Status, m.statusLine())
	}
	if m.statusRevision != revision+1 {
		t.Fatalf("replayed events outdated the status reply in flight: revision %d → %d", revision, m.statusRevision)
	}
	send(daemon.StreamEvent{Type: daemon.EventThinking, Text: "live"})
	if !m.Status.Running || m.statusLine() != "thinking" {
		t.Fatalf("a live thought should still mark it running: %q", m.statusLine())
	}
}
