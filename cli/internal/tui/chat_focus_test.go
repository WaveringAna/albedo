// What the client wakes up for decides what it costs while nobody is doing
// anything: a face tick and its frame, a status read and its frame, or
// nothing at all. Those counts are invisible from outside the process (one
// request per poll, a face that never leaves the terminal), so the animation
// decisions and the one poll loop are checked here.
package tui

import (
	"testing"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/daemon/protocol"
	tea "charm.land/bubbletea/v2"
)

// workingStatus is a session with a turn in flight: the state the face is for.
func workingStatus() daemon.AgentStatus {
	phase := daemon.PhaseTool
	return daemon.AgentStatus{Running: true, Phase: &phase, KernelLink: "attached"}
}

func TestAnIdleBackgroundJobRestsWithoutAFace(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 30)
	m.Status = daemon.AgentStatus{
		Idle:        true,
		KernelLink:  "attached",
		KernelJobs:  new(int64(1)),
		RunningJobs: []protocol.KernelJob{{ID: "job", Command: "sleep 10"}},
	}
	if m.animating() {
		t.Fatal("an idle session with a job running animated the face")
	}
	if got := m.statusLine(); got != "1 background job running · sleep 10" {
		t.Fatalf("the background work marker reads %q", got)
	}
	if cmd := m.startAnimation(); cmd != nil || m.animationActive {
		t.Fatal("an idle background job started the face")
	}
	// a tick already in flight ends the animation rather than carrying it on
	if _, cmd := m.Update(ChatProgressTickMsg{SessionID: m.SessionID, Generation: m.Generation}); cmd != nil || m.animationActive {
		t.Fatal("a face tick kept the animation alive for background work")
	}
	// and a live event still outdates a status reply in flight without asking
	// for another read: the pushed events carry what it would have said
	polls, revision := m.statusPoll, m.statusRevision
	updated, streamCmd := m.Update(ChatStreamEventMsg{SessionID: m.SessionID, Generation: m.Generation,
		Event: daemon.StreamEvent{Type: daemon.EventNote}})
	m = updated
	if streamCmd == nil || m.statusPoll != polls {
		t.Fatal("a live event scheduled a status read")
	}
	if m.statusRevision == revision {
		t.Fatal("a live event did not outdate the status reply in flight")
	}
}

func TestWaitingOnATurnAnimates(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 30)
	m.Status = workingStatus()
	if !m.animating() {
		t.Fatal("a turn in flight did not animate")
	}
	if cmd := m.startAnimation(); cmd == nil || !m.animationActive {
		t.Fatal("a turn in flight did not start the face")
	}
	if _, cmd := m.Update(ChatProgressTickMsg{SessionID: m.SessionID, Generation: m.Generation}); cmd == nil {
		t.Fatal("the face stopped while the turn was still running")
	}
	// a status reply keeps exactly one poll going, whichever state it found
	polls := m.statusPoll
	updated, statusReply := m.Update(ChatStatusMsg{SessionID: m.SessionID, Generation: m.Generation,
		Revision: m.statusRevision, Status: &m.Status})
	m = updated
	if statusReply == nil || m.statusPoll != polls+1 {
		t.Fatalf("a status reply left %d polls scheduled", m.statusPoll-polls)
	}
}

func TestBlurStopsTheFaceUntilFocus(t *testing.T) {
	app := newTestApp(t)
	chat := &app.Chat
	chat.Status = workingStatus()
	if cmd := chat.startAnimation(); cmd == nil || !chat.animationActive {
		t.Fatal("a running turn did not start the face")
	}

	// the terminal reports it lost focus
	if _, cmd := app.Update(tea.BlurMsg{}); cmd != nil {
		t.Fatal("losing focus drew something")
	}
	if !chat.blurred {
		t.Fatal("the chat did not note the blurred terminal")
	}
	if cmd := chat.startAnimation(); cmd != nil {
		t.Fatal("a blurred terminal started the face")
	}
	updated, cmd := chat.Update(ChatProgressTickMsg{SessionID: chat.SessionID, Generation: chat.Generation})
	*chat = updated
	if cmd != nil || chat.animationActive {
		t.Fatal("a blurred terminal kept a face tick going")
	}

	// focus back: one status read now, and the face moves again
	_, focusCmd := app.Update(tea.FocusMsg{})
	if focusCmd == nil {
		t.Fatal("regaining focus did not read status")
	}
	if chat.blurred {
		t.Fatal("the chat still reads as blurred after focus")
	}
	// focus starts the face itself, so the loop is live again without waiting
	// for another tick to arrive
	if !chat.animationActive {
		t.Fatal("focus did not restart the face")
	}
}

func TestOnlyTheNewestScheduledPollReadsStatus(t *testing.T) {
	// An extra status read once forked a second loop that never ended; the
	// counter is what makes every poll but the newest harmless.
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.Status = daemon.AgentStatus{Idle: true, KernelLink: "attached"}
	stale := m.statusPoll
	m.statusPollCmd()
	if _, cmd := m.Update(ChatStatusPollMsg{SessionID: m.SessionID, Generation: m.Generation, Poll: stale}); cmd != nil {
		t.Fatal("a superseded poll read status again")
	}
	if _, cmd := m.Update(ChatStatusPollMsg{SessionID: m.SessionID, Generation: m.Generation, Poll: m.statusPoll}); cmd == nil {
		t.Fatal("the newest poll did not read status")
	}
}

// A terminal reports focus as soon as the program starts, often while the
// session picker or the login screen is up and no chat has a client yet.
func TestFocusBeforeAnyChatReadsNothing(t *testing.T) {
	var app AppModel
	updated, cmd := app.Update(tea.FocusMsg{})
	if cmd != nil {
		t.Fatalf("focus without a chat asked for %T", cmd())
	}
	if _, cmd := updated.Update(tea.BlurMsg{}); cmd != nil {
		t.Fatal("blur without a chat asked for a command")
	}
}
