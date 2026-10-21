package tui

import (
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"slices"

	tea "charm.land/bubbletea/v2"
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
	// The reply is the client's listing: the sessions screen shares it rather
	// than keeping a copy of it.
	m.Sessions = sessions
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

// sessionFactsMsg is the session representation a refresh read.
type sessionFactsMsg struct {
	SessionID string
	Session   daemon.Session
	Err       error
	Gen       int
}

// refreshSessionFactsCmd reads the active session again. The daemon changes it
// under the session: a command, another client, or the session's own compaction
// can save its configuration, and a child spawns or closes beside it, so a copy
// observed before any of them is refused when it is used. One read in flight at
// a time answers all of them, and one that arrives meanwhile is read once more.
func (m *AppModel) refreshSessionFactsCmd() tea.Cmd {
	if m.Conn == nil || m.ActiveSession == nil {
		return nil
	}
	if m.refreshingSession {
		m.sessionRefreshPending = true
		return nil
	}
	m.refreshingSession = true
	m.SessionFactsGen++
	conn, id, gen := m.Conn, m.ActiveSession.ID, m.SessionFactsGen
	return func() tea.Msg {
		session, err := daemon.GetSession(context.Background(), conn, id)
		return sessionFactsMsg{SessionID: id, Session: session, Err: err, Gen: gen}
	}
}

// applySessionFacts takes what the daemon reported for the active session: the
// validators its next change has to match, and the values it shows.
func (m *AppModel) applySessionFacts(msg sessionFactsMsg) {
	if msg.Err != nil || m.ActiveSession == nil || m.ActiveSession.ID != msg.SessionID {
		return
	}
	read := msg.Session
	session := *m.ActiveSession
	windowChanged := windowTokens(read.ContextWindow) != windowTokens(session.ContextWindow)
	session.ETag, session.FamilyRevision = read.ETag, read.FamilyRevision
	session.Model, session.Effort, session.Provider = read.Model, read.Effort, read.Provider
	session.ContextWindow = read.ContextWindow
	if profile, known := m.Profiles.Providers[session.Provider]; known {
		session.Protocol = profile.Protocol
	}
	m.updateSession(session)
	m.Chat.Model, m.Chat.Effort, m.Chat.Provider = session.Model, session.Effort, session.Provider
	// The footer otherwise keeps the window its own read found.
	if windowChanged && read.ContextWindow != nil {
		tokens := int(*read.ContextWindow)
		m.Chat.window, m.Chat.windowModel = &tokens, &session.Model
	} else if windowChanged {
		m.Chat.window, m.Chat.windowModel = nil, nil
	}
}

// refusedConfigurationCmd refreshes what a refused conditional change was
// based on. The copy on screen is no longer the daemon's, so the same change
// would keep being refused until the session was closed and opened again, or
// the client restarted.
func (m *AppModel) refusedConfigurationCmd(err error) tea.Cmd {
	// A model change saves the provider default it switches to as well.
	if apiErr, known := errors.AsType[*daemon.APIError](err); known && apiErr.Code == "settings_changed" {
		return m.refreshSettingsCmd()
	}
	if refusedConfiguration(err) {
		return m.refreshSessionFactsCmd()
	}
	return nil
}

// windowTokens reads a context window override; zero means none.
func windowTokens(value *int64) int64 {
	if value == nil {
		return 0
	}
	return *value
}

// sessionCondition is the observed state a workspace move is conditional on.
func (m *AppModel) sessionCondition() daemon.SessionCondition {
	if m.ActiveSession == nil {
		return daemon.SessionCondition{}
	}
	return daemon.SessionCondition{ETag: m.ActiveSession.ETag, FamilyRevision: m.ActiveSession.FamilyRevision}
}
