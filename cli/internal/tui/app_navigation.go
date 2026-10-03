package tui

import (
	"albedo/cli/internal/daemon"
	"slices"

	tea "charm.land/bubbletea/v2"
)

func (m AppModel) initScreen() tea.Cmd {
	switch m.State {
	case AppStateChat:
		return tea.Batch(m.Chat.Init(), m.loadCommandCatalogCmd(m.CatalogGen), m.recordOpenCmd(m.ActiveSession.ID))
	case AppStateLogin:
		if !m.StandaloneLogin && m.ActiveSession == nil {
			return tea.Batch(m.Login.Init(), m.loadSessionsCmd(m.SessionGen))
		}
		return m.Login.Init()
	case AppStateSessionPicker:
		return tea.Batch(m.SessionPicker.Init(), m.loadSessionsCmd(m.SessionGen), m.loadSettingsCmd(m.SettingsGen))
	}
	return nil
}

func (m *AppModel) returnToChat() tea.Cmd {
	if m.Chat.SessionID != m.ActiveSession.ID {
		return tea.Batch(m.setChatSession(*m.ActiveSession, false), m.recordOpenCmd(m.ActiveSession.ID))
	}
	m.State = AppStateChat
	return nil
}

func (m *AppModel) openLogin(name string) tea.Cmd {
	previous := m.Login.Close()
	m.Login = NewLoginModel(m.Conn, name, m.openBrowser)
	m.Login.SetSize(m.Width, m.Height)
	m.State = AppStateLogin
	return tea.Batch(previous, m.Login.Init())
}

func (m *AppModel) openSessions() tea.Cmd {
	m.State = AppStateSessionPicker
	m.SessionGen++
	return tea.Batch(m.SessionPicker.Init(), m.loadSessionsCmd(m.SessionGen), m.loadSettingsCmd(m.SettingsGen))
}

type screen interface {
	SetSize(int, int)
	Init() tea.Cmd
}

func (m *AppModel) openScreen(state AppState, s screen) tea.Cmd {
	s.SetSize(m.Width, m.Height)
	m.State = state
	return s.Init()
}

func (m *AppModel) openModelPicker() tea.Cmd {
	if m.ActiveSession == nil {
		return nil
	}
	m.ModelPicker.Close()
	m.ModelPicker = NewModelPickerModel(m.Conn, m.Profiles, m.ActiveSession.Model, m.ActiveSession.Provider, m.ActiveSession.Effort)
	return m.openScreen(AppStateModelPicker, &m.ModelPicker)
}

func (m *AppModel) openExtensionPicker() tea.Cmd {
	if m.ActiveSession == nil {
		return nil
	}
	m.ExtensionPicker = NewExtensionPickerModel(m.Conn, m.ActiveSession.ID)
	return m.openScreen(AppStateExtensionPicker, &m.ExtensionPicker)
}

func (m *AppModel) openTreePicker() tea.Cmd {
	if m.ActiveSession == nil {
		return nil
	}
	m.TreePicker = NewTreePickerModel(m.Conn, m.ActiveSession.ID)
	return m.openScreen(AppStateTreePicker, &m.TreePicker)
}

func (m *AppModel) openContextInspector() tea.Cmd {
	if m.ActiveSession == nil {
		return nil
	}
	m.ContextInspector = NewContextInspectorModel(m.Conn, m.ActiveSession.ID)
	return m.openScreen(AppStateContextInspector, &m.ContextInspector)
}

// openFolderPicker offers the session another folder; a retry is the turn
// its missing folder refused.
func (m *AppModel) openFolderPicker(retry *WorkspaceRetry) tea.Cmd {
	if m.ActiveSession == nil {
		return nil
	}
	m.FolderPicker.Close()
	m.FolderPicker = NewFolderPicker(daemonFolders{conn: m.Conn, condition: daemon.SessionCondition{ETag: m.ActiveSession.ETag, FamilyRevision: m.ActiveSession.FamilyRevision}}, *m.ActiveSession, retry)
	m.folderReturn = AppStateChat
	return m.openScreen(AppStateFolderPicker, &m.FolderPicker)
}

// openFolderBrowser lists sessions by folder, from the sessions view.
func (m *AppModel) openFolderBrowser(query string) tea.Cmd {
	m.FolderPicker.Close()
	m.FolderPicker = NewFolderBrowser(daemonFolders{conn: m.Conn}, m.Workspace, query)
	m.folderReturn = AppStateSessionPicker
	return m.openScreen(AppStateFolderPicker, &m.FolderPicker)
}

// moved takes the daemon's answer to moving the session on screen.
func (m *AppModel) moved(msg FolderMovedMsg) tea.Cmd {
	if m.ActiveSession == nil || msg.SessionID != m.ActiveSession.ID {
		return nil
	}
	if msg.Err != nil {
		if m.State == AppStateFolderPicker {
			m.FolderPicker.Refused(msg.Err)
		} else {
			m.AddError(operationError(msg.Err, "Could not move this session: ", "Session may have moved; check its folder before trying again."))
		}
		return nil
	}
	if msg.Session != nil && msg.Session.ETag != "" {
		captured := *msg.Session
		m.ActiveSession = &captured
		m.SessionPicker.Renamed(captured)
	}
	m.ActiveSession.Workspace, m.ActiveSession.Location, m.Workspace = msg.Workspace, msg.Location, msg.Workspace
	if i := slices.IndexFunc(m.Sessions, func(s daemon.Session) bool { return s.ID == msg.SessionID }); i >= 0 {
		m.Sessions[i] = *m.ActiveSession
	}
	m.State = AppStateChat
	return m.Chat.Moved(*m.ActiveSession, msg.Retry)
}

// Close releases this application's reads and subscriptions. Shared daemon
// work and admitted mutations continue independently of the terminal.
func (m *AppModel) Close() tea.Cmd {
	m.Chat.Close()
	m.Agents.Close()
	m.ModelPicker.Close()
	m.FolderPicker.Close()
	return m.Login.Close()
}
