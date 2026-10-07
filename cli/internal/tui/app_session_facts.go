package tui

import (
	"albedo/cli/internal/daemon"
	"slices"
)

func (m *AppModel) session(id string) (daemon.Session, bool) {
	if m.ActiveSession != nil && m.ActiveSession.ID == id {
		return *m.ActiveSession, true
	}
	if i := slices.IndexFunc(m.Sessions, func(s daemon.Session) bool { return s.ID == id }); i >= 0 {
		return m.Sessions[i], true
	}
	return daemon.Session{}, false
}

func (m *AppModel) updateSession(session daemon.Session) {
	if i := slices.IndexFunc(m.Sessions, func(s daemon.Session) bool { return s.ID == session.ID }); i >= 0 {
		m.Sessions[i] = session
	}
	if m.ActiveSession != nil && m.ActiveSession.ID == session.ID {
		captured := session
		m.ActiveSession = &captured
	}
	m.updateSessionPickerItems()
}

func (m *AppModel) applySessionList(sessions []daemon.Session) {
	m.Sessions = slices.Clone(sessions)
	if m.ActiveSession != nil {
		if i := slices.IndexFunc(sessions, func(s daemon.Session) bool { return s.ID == m.ActiveSession.ID }); i >= 0 {
			// Listings omit details available from a session snapshot.
			captured := *m.ActiveSession
			listed := sessions[i]
			captured.Title, captured.Pinned, captured.Archived, captured.Opens = listed.Title, listed.Pinned, listed.Archived, listed.Opens
			if listed.ETag != "" {
				captured.ETag = listed.ETag
			}
			m.ActiveSession = &captured
		}
	}
	m.updateSessionPickerItems()
}
