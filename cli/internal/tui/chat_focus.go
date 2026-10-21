package tui

import (
	"time"

	tea "charm.land/bubbletea/v2"
)

// A terminal that reports focus tells the client whether anyone is looking at
// it: while it is unfocused the face stops animating, and coming back reads
// status at once, so the first frame drawn is current. A terminal that never
// reports focus never blurs.

// statusSafetyPoll is the one status read a healthy stream still gets. The
// daemon pushes the kernel's job facts and the sidebar's glances as they
// change, and the stream's own reset carries everything on attach, so this is
// only here for a daemon too old to push them; anything else would be a read
// that says what the last event already said.
const statusSafetyPoll = 60 * time.Second

// statusPollCmd schedules the next status read. Only the newest scheduled poll
// fires, so a status read started elsewhere never adds a second polling loop.
func (m *ChatModel) statusPollCmd() tea.Cmd {
	m.statusPoll++
	id, generation, poll := m.SessionID, m.Generation, m.statusPoll
	return tea.Tick(statusSafetyPoll, func(time.Time) tea.Msg { return ChatStatusPollMsg{SessionID: id, Generation: generation, Poll: poll} })
}

// focus follows the terminal's focus: losing it stops the face, and regaining
// it reads status at once and lets the face move again.
func (m *ChatModel) focus(focused bool) tea.Cmd {
	m.blurred = !focused
	if m.blurred {
		return nil
	}
	return tea.Batch(m.startAnimation(), m.statusCmd())
}
