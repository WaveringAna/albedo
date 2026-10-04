package tui

import (
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"maps"
	"slices"
	"time"

	tea "charm.land/bubbletea/v2"
)

func (m *AppModel) handleSessionResults(msg tea.Msg) (tea.Cmd, bool) {
	switch msg := msg.(type) {
	case sessionDeletedMsg:
		if msg.Err != nil {
			m.AddError(operationError(msg.Err, "Could not delete the session: ", "Session may have been deleted; refresh the session list before trying again."))
			return nil, true
		}
		m.ClearNotices()
		if msg.Result == nil {
			return nil, true
		}
		deleted := slices.Clone(msg.Result.DeletedIDs)
		if msg.Result.OK && !slices.Contains(deleted, msg.ID) {
			deleted = append(deleted, msg.ID)
		}
		for _, id := range deleted {
			delete(m.pendingBySession, id)
			m.SessionPicker.Removed(id)
		}
		m.Sessions = slices.DeleteFunc(m.Sessions, func(s daemon.Session) bool { return slices.Contains(deleted, s.ID) })
		if !msg.Result.OK || msg.Result.Truncated {
			m.AddNotice(msg.Result.Message)
			m.SessionPicker.notice = msg.Result.Message
			m.SessionGen++
			return m.loadSessionsCmd(m.SessionGen, msg.Result.Message), true
		}
		return nil, true
	case SessionRenameMsg:
		return m.renameSessionCmd(msg), true
	case sessionRenamedMsg:
		var cmd tea.Cmd
		if m.State == AppStateAgents {
			m.Agents, cmd = m.Agents.Update(msg)
		}
		if msg.Err != nil {
			m.SessionPicker.notice = operationError(msg.Err, "Could not rename the session: ", "Session may have been renamed; refresh the session list before trying again.")
			return cmd, true
		}
		if i := slices.IndexFunc(m.Sessions, func(s daemon.Session) bool { return s.ID == msg.ID }); i >= 0 {
			m.Sessions[i] = msg.Session
		}
		if m.ActiveSession != nil && m.ActiveSession.ID == msg.ID {
			captured := msg.Session
			m.ActiveSession = &captured
		}
		m.SessionPicker.notice = ""
		m.SessionPicker.Renamed(msg.Session)
		return cmd, true
	case sessionsLoadedMsg:
		if msg.Gen != m.SessionGen {
			return nil, true
		}
		if msg.Err != nil {
			m.SessionPicker.Loading = false
			m.AddError("Could not load sessions: " + msg.Err.Error())
			return nil, true
		}
		m.Sessions = msg.Sessions
		m.SessionPicker.prefs.Pinned = nil
		m.SessionPicker.prefs.Archived = nil
		m.SessionPicker.prefs.Opens = map[string]int{}
		for _, session := range msg.Sessions {
			if session.Pinned {
				m.SessionPicker.prefs.Pinned = append(m.SessionPicker.prefs.Pinned, session.ID)
			}
			if session.Archived {
				m.SessionPicker.prefs.Archived = append(m.SessionPicker.prefs.Archived, session.ID)
			}
			m.SessionPicker.prefs.Opens[session.ID] = session.Opens
		}
		m.ClearNotices()
		m.SessionPicker.Prune(msg.Sessions)
		m.updateSessionPickerItems()
		if msg.Notice != "" {
			m.AddNotice(msg.Notice)
			m.SessionPicker.notice = msg.Notice
		}
		return m.SessionPicker.PreviewCmd(), true
	case sessionCreationRecoveryMsg:
		if pending, exists := m.pendingCreations[msg.Handle.ID()]; !exists || pending.Expired {
			return nil, true
		}
		conn, handle, gen := m.Conn, msg.Handle, msg.Gen
		return func() tea.Msg {
			session, err := daemon.ResolveCreation(context.Background(), conn, handle)
			return sessionCreatedMsg{Session: session, Err: err, Handle: handle, Gen: gen}
		}, true
	case sessionCreatedMsg:
		if msg.Gen != m.SessionGen && (msg.Handle == nil || m.pendingCreations[msg.Handle.ID()].Handle == nil) {
			return nil, true
		}
		if msg.Handle != nil && daemon.IsOperationExpired(msg.Err) {
			pending := m.pendingCreations[msg.Handle.ID()]
			pending.Expired = true
			m.pendingCreations[msg.Handle.ID()] = pending
			m.AddError("Session operation " + msg.Handle.ID() + " expired; its outcome is unresolved.")
			return nil, true
		}
		if msg.Err != nil && msg.Handle != nil {
			if _, uncertain := errors.AsType[*daemon.UncertainOutcomeError](msg.Err); uncertain {
				m.AddError("Session admission is uncertain. Checking operation " + msg.Handle.ID() + ".")
				return creationRecoveryCmd(msg.Handle, msg.Gen), true
			}
			if api, ok := errors.AsType[*daemon.APIError](msg.Err); ok && (api.Code == "operation_unknown" || api.StatusCode >= 500) {
				return creationRecoveryCmd(msg.Handle, msg.Gen), true
			}
		}
		if msg.Handle != nil {
			delete(m.pendingCreations, msg.Handle.ID())
		}
		if msg.Gen != m.SessionGen {
			if msg.Err != nil {
				m.AddError(msg.Err.Error())
				return nil, true
			}
			if !slices.ContainsFunc(m.Sessions, func(session daemon.Session) bool { return session.ID == msg.Session.ID }) {
				m.Sessions = append(m.Sessions, msg.Session)
			}
			m.updateSessionPickerItems()
			m.ClearNotices()
			m.AddNotice("Recovered the created session " + msg.Session.ID)
			return nil, true
		}
		if msg.Err != nil && m.State == AppStateFolderPicker {
			m.FolderPicker.Refused(errors.New(operationError(msg.Err, "", "Session may have been created; check the session list before creating another.")))
			return nil, true
		}
		if msg.Err != nil {
			m.AddError(operationError(msg.Err, "Could not create a session: ", "Session may have been created; check the session list before creating another."))
			return nil, true
		}
		return m.setChatSession(msg.Session, true), true
	}
	return nil, false
}

func (m *AppModel) loadSessionsCmd(gen int, notices ...string) tea.Cmd {
	conn := m.Conn
	notice := ""
	if len(notices) > 0 {
		notice = notices[0]
	}
	return func() tea.Msg {
		if conn == nil {
			return sessionsLoadedMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}
		sessions, err := daemon.ListSessions(context.Background(), conn)
		return sessionsLoadedMsg{Sessions: sessions, Err: err, Gen: gen, Notice: notice}
	}
}

func (m *AppModel) renameSessionCmd(rename SessionRenameMsg) tea.Cmd {
	conn := m.Conn
	return func() tea.Msg {
		if conn == nil {
			return sessionRenamedMsg{SessionRenameMsg: rename, Err: errors.New("daemon connection unavailable")}
		}
		s, err := daemon.RenameSession(context.Background(), conn, rename.ID, rename.Name, rename.ETag)
		return sessionRenamedMsg{SessionRenameMsg: rename, Session: s, Err: err}
	}
}

func (m *AppModel) deleteSessionCmd(id string, condition daemon.SessionCondition) tea.Cmd {
	conn := m.Conn
	return func() tea.Msg {
		if conn == nil {
			return sessionDeletedMsg{ID: id, Err: errors.New("daemon connection unavailable")}
		}
		result, err := daemon.DeleteSession(context.Background(), conn, id, true, condition)
		return sessionDeletedMsg{ID: id, Err: err, Result: &result}
	}
}

func sessionPreviewCmd(conn *daemon.Connection, id string) tea.Cmd {
	return func() tea.Msg {
		preview, err := daemon.PreviewHistory(context.Background(), conn, id, 16)
		return SessionPreviewMsg{ID: id, Preview: preview, Err: err}
	}
}

func (m *AppModel) createSessionCmd(gen int, workspace string) tea.Cmd {
	conn := m.Conn
	handle, preparationErr := daemon.NewCreation(daemon.CreateSessionRequest{Workspace: workspace})
	if preparationErr == nil {
		if m.pendingCreations == nil {
			m.pendingCreations = make(map[string]pendingOperation)
		}
		m.pendingCreations[handle.ID()] = pendingOperation{Handle: handle}
	}
	return func() tea.Msg {
		if preparationErr != nil {
			return sessionCreatedMsg{Err: preparationErr, Gen: gen}
		}
		if conn == nil {
			return sessionCreatedMsg{Err: errors.New("daemon connection unavailable"), Gen: gen, Handle: handle}
		}
		session, err := daemon.CreateSessionOperation(context.Background(), conn, handle)
		return sessionCreatedMsg{Session: session, Err: err, Gen: gen, Handle: handle}
	}
}

func creationRecoveryCmd(handle *daemon.OperationHandle, gen int) tea.Cmd {
	return tea.Tick(15*time.Second, func(time.Time) tea.Msg { return sessionCreationRecoveryMsg{Handle: handle, Gen: gen} })
}

func (m *AppModel) updateSessionPickerItems() {
	m.SessionPicker.SetSessions(m.Sessions, m.ActiveSession)
}

func (m *AppModel) setChatSession(s daemon.Session, prepend bool) tea.Cmd {
	m.SessionGen++
	if m.pendingBySession == nil {
		m.pendingBySession = make(map[string]pendingSessionIntents)
	}
	if m.Chat.SessionID != "" {
		if len(m.Chat.pendingUsers) == 0 && len(m.Chat.pendingContinuations) == 0 {
			delete(m.pendingBySession, m.Chat.SessionID)
		} else {
			m.pendingBySession[m.Chat.SessionID] = pendingSessionIntents{users: slices.Clone(m.Chat.pendingUsers), continuations: maps.Clone(m.Chat.pendingContinuations)}
		}
	}
	m.Chat.Close()
	session := s
	m.ActiveSession = &session
	if prepend {
		m.Sessions = append([]daemon.Session{s}, m.Sessions...)
	}
	m.Chat = m.newChatModel(&session)
	m.Chat.SetSize(m.Width, m.Height)
	m.State = AppStateChat
	m.CatalogGen++
	return tea.Batch(m.Chat.Init(), m.loadCommandCatalogCmd(m.CatalogGen))
}

// openSession makes session the chat on screen.
func (m *AppModel) openSession(s daemon.Session) tea.Cmd {
	m.ClearNotices()
	return tea.Batch(m.setChatSession(s, false), m.recordOpenCmd(s.ID))
}

func (m *AppModel) newSessionCmd() tea.Cmd {
	m.SessionGen++
	return m.createSessionCmd(m.SessionGen, m.Workspace)
}
