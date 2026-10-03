// Package tui implements the interactive CLI and its terminal views.
package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"errors"
	"maps"
	"slices"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

type AppState int

const (
	AppStateChat AppState = iota
	AppStateSessionPicker
	AppStateModelPicker
	AppStateExtensionPicker
	AppStateTreePicker
	AppStateContextInspector
	AppStatePageView
	AppStateLogin
	AppStateCapabilityPage
	AppStateWebhooksPage
	AppStateAgents
	AppStateFolderPicker
)

type pendingSessionIntents struct {
	users         []PendingUserTurn
	continuations map[string]pendingOperation
}

type AppModel struct {
	pendingBySession map[string]pendingSessionIntents
	pendingCreations map[string]pendingOperation
	ActiveSession    *daemon.Session
	openBrowser      func(url string)
	Conn             *daemon.Connection
	Profiles         config.Profiles
	SettingsETags    map[string]string
	Workspace        string
	Sessions         []daemon.Session
	Notices          Notices
	CommandCatalog   []daemon.SessionCommand
	ExtensionPicker  ExtensionPickerModel
	CapabilityPage   CapabilityPageModel
	WebhooksPage     WebhooksPageModel
	TreePicker       TreePickerModel
	SessionPicker    SessionViewer
	PageView         PageViewModel
	ContextInspector ContextInspectorModel
	Login            LoginModel
	ModelPicker      ModelPickerModel
	FolderPicker     FolderPicker
	Agents           AgentsViewModel

	Chat              ChatModel
	SettingsGen       int
	State             AppState
	Width             int
	Height            int
	ExtensionRevision int

	// SessionGen invalidates earlier session-list and session-creation replies.
	SessionGen int
	CatalogGen int
	ModelGen   int
	CommandGen int
	ProfileGen int
	// folderReturn is the screen the folder picker goes back to.
	folderReturn    AppState
	UISaving        bool
	StandaloneLogin bool

	// Graphemes says the terminal measures grapheme clusters; see ChatModel.
	Graphemes bool
}

func (m *AppModel) newChatModel(session *daemon.Session) ChatModel {
	chat := NewChatModel(session, daemon.NewChatClient(m.Conn, session.ID))
	if pending, ok := m.pendingBySession[session.ID]; ok {
		chat.pendingUsers = slices.Clone(pending.users)
		chat.pendingContinuations = maps.Clone(pending.continuations)
		delete(m.pendingBySession, session.ID)
	}
	chat.Flags.Thinking = m.SessionPicker.prefs.Thinking
	chat.Flags.Tools = m.SessionPicker.prefs.Tools
	chat.Notices = slices.Clone(m.Notices)
	chat.graphemes = m.Graphemes
	m.Notices = nil
	return chat
}

// NewAppModel requires an established daemon connection and panics if conn is nil.
func NewAppModel(conn *daemon.Connection, profiles config.Profiles, initialSession *daemon.Session, workspace string, needsLogin bool, openBrowser func(string)) AppModel {
	if conn == nil {
		panic("tui.NewAppModel requires a daemon connection")
	}
	m := AppModel{
		Conn:          conn,
		Profiles:      profiles,
		ActiveSession: initialSession,
		Workspace:     workspace,
		openBrowser:   openBrowser,
	}

	if needsLogin {
		m.State = AppStateLogin
		m.Login = NewLoginModel(conn, "", openBrowser)
	} else if initialSession != nil {
		m.State = AppStateChat
		m.Chat = m.newChatModel(initialSession)
	} else {
		m.State = AppStateSessionPicker
	}
	// Built even when starting in a session so /sessions has a working search.
	m.SessionPicker = NewSessionViewer(workspace)
	m.SessionPicker.Fetch = func(id string) tea.Cmd {
		return sessionPreviewCmd(conn, id)
	}

	return m
}

// NewLoginAppModel starts the standalone login flow, which exits when finished.
func NewLoginAppModel(conn *daemon.Connection, profiles config.Profiles, workspace, nameHint string, openBrowser func(string)) AppModel {
	m := NewAppModel(conn, profiles, nil, workspace, false, openBrowser)
	m.State = AppStateLogin
	m.StandaloneLogin = true
	m.Login = NewLoginModel(conn, nameHint, openBrowser)
	return m
}

func (m AppModel) Init() tea.Cmd {
	return tea.Batch(m.initScreen(), m.loadSettingsCmd(m.SettingsGen))
}

func (m *AppModel) AddNotice(message string) {
	if m.ActiveSession != nil && m.Chat.History != nil {
		m.Chat.AddNotice(message)
		return
	}
	m.Notices.AddNotice(message)
}

func (m *AppModel) AddError(message string) {
	if m.ActiveSession != nil && m.Chat.History != nil {
		m.Chat.AddError(message)
		return
	}
	m.Notices.AddError(message)
}

func (m *AppModel) ClearNotices() {
	m.Notices.Clear()
	if m.ActiveSession != nil && m.Chat.History != nil {
		m.Chat.ClearNotices()
	}
}

func (m AppModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if cmd, handled := m.handleCommandInvocation(msg); handled {
		return m, cmd
	}
	if handled, cmd := m.handleLoginOutcome(msg); handled {
		return m, cmd
	}
	if cmd, handled := m.handleChatLifecycle(msg); handled {
		return m, cmd
	}

	if cmd, handled := m.handlePreferences(msg); handled {
		return m, cmd
	}
	if cmd, handled := m.handleSessionResults(msg); handled {
		return m, cmd
	}
	if cmd, handled := m.handleCommandResults(msg); handled {
		return m, cmd
	}

	switch msg := msg.(type) {

	case tea.WindowSizeMsg:
		m.Width = msg.Width
		m.Height = msg.Height
		if m.ActiveSession != nil && m.Chat.History != nil {
			m.Chat.SetSize(msg.Width, msg.Height)
		}
		m.SessionPicker.SetSize(msg.Width, msg.Height)
		m.ModelPicker.SetSize(msg.Width, msg.Height)
		m.ExtensionPicker.SetSize(msg.Width, msg.Height)
		m.TreePicker.SetSize(msg.Width, msg.Height)
		m.ContextInspector.SetSize(msg.Width, msg.Height)
		m.PageView.SetSize(msg.Width, msg.Height)
		m.CapabilityPage.SetSize(msg.Width, msg.Height)
		m.WebhooksPage.SetSize(msg.Width, msg.Height)
		m.Agents.SetSize(msg.Width, msg.Height)
		m.FolderPicker.SetSize(msg.Width, msg.Height)
		m.Login.SetSize(msg.Width, msg.Height)
		return m, nil

	case tea.ModeReportMsg:
		// the reply Bubble Tea switches to grapheme widths on
		if msg.Mode == ansi.ModeUnicodeCore {
			switch msg.Value {
			case ansi.ModeReset, ansi.ModeSet, ansi.ModePermanentlySet:
				m.Graphemes = true
				m.Chat.graphemes = true
			}
		}
		return m, nil

	case SessionDeleteMsg:
		if m.State != AppStateSessionPicker || !m.SessionPicker.ArchiveView || m.ActiveSession != nil && m.ActiveSession.ID == msg.ID {
			return m, nil
		}
		return m, m.deleteSessionCmd(msg.ID, msg.Condition)

	case commandCatalogLoadedMsg:
		if msg.Gen != m.CatalogGen {
			return m, nil
		}
		if msg.Err != nil {
			if _, ok := errors.AsType[*daemon.UpgradeRequiredError](msg.Err); ok {
				m.AddError("Could not load commands: " + msg.Err.Error())
			}
			return m, nil
		}
		m.CommandCatalog = msg.Commands
		m.Chat.CommandMenu.Catalog = msg.Commands
		return m, nil

	case ChatQuitMsg:
		m.Chat.Close()
		return m, tea.Quit

	case ChatBackToSessionsMsg:
		return m, m.openSessions()

	case ChatNewSessionMsg:
		return m, m.newSessionCmd()

	case ChatOpenModelPickerMsg:
		return m, m.openModelPicker()

	case ModelPickerSelectMsg:
		m.ModelPicker.Close()
		m.ModelPicker.Saving = true
		m.ModelPicker.Error = ""
		m.ModelGen++
		return m, m.changeModelCmd(msg.Model, msg.Provider, msg.Effort, msg.RaiseCap, m.ModelGen, msg.CapKey)

	case ChatOpenExtensionPickerMsg:
		return m, m.openExtensionPicker()

	case ChatOpenWebhooksPageMsg:
		if m.ActiveSession != nil {
			m.WebhooksPage = NewWebhooksPageModel(m.Conn, m.ActiveSession.ID)
			return m, m.openScreen(AppStateWebhooksPage, &m.WebhooksPage)
		}

	case ChatOpenAgentsMsg:
		if m.ActiveSession != nil {
			m.Agents.Close()
			pending := m.Agents.pendingOperations
			draft := m.Agents.input.Value()
			m.Agents = NewAgentsViewModel(m.Conn, m.ActiveSession.ID)
			m.Agents.pendingOperations = pending
			m.Agents.input.SetValue(draft)
			return m, m.openScreen(AppStateAgents, &m.Agents)
		}
	case agentsSentMsg:
		if m.State != AppStateAgents && msg.Handle != nil {
			var cmd tea.Cmd
			m.Agents, cmd = m.Agents.Update(msg)
			return m, cmd
		}

	case ChatOpenFolderPickerMsg:
		return m, m.openFolderPicker(msg.Retry)

	case FolderMovedMsg:
		return m, m.moved(msg)

	case FolderPickerCancelMsg:
		m.FolderPicker.Close()
		m.State = m.folderReturn
		return m, nil

	case SessionFoldersMsg:
		return m, m.openFolderBrowser(msg.Query)

	case FolderOpenSessionMsg:
		m.FolderPicker.Close()
		return m, m.openSession(msg.Session)

	case FolderNewSessionMsg:
		m.FolderPicker.Close()
		m.SessionGen++
		return m, m.createSessionCmd(m.SessionGen, msg.Workspace)

	case AgentsDoneMsg:
		m.Agents.Close()
		m.State = AppStateChat
		return m, nil

	case AgentsAttachMsg:
		m.Agents.Close()
		session := msg.Session
		if i := slices.IndexFunc(m.Sessions, func(s daemon.Session) bool { return s.ID == session.ID }); i >= 0 {
			session = m.Sessions[i]
		}
		return m, m.openSession(session)

	case ModelPickerCancelMsg:
		m.ModelPicker.Close()
		m.State = AppStateChat
		return m, nil

	case WebhooksPageDoneMsg, ExtensionPickerDoneMsg,
		TreeCancelMsg, ContextDoneMsg, CapabilityPageDoneMsg, PageCancelMsg:
		m.State = AppStateChat
		return m, nil

	case ExtensionPickerChangedMsg:
		m.ExtensionRevision++
		m.CatalogGen++
		return m, m.loadCommandCatalogCmd(m.CatalogGen)

	case CapabilityPageChangedMsg:
		m.CatalogGen++
		return m, m.loadCommandCatalogCmd(m.CatalogGen)

	case ChatOpenTreePickerMsg:
		return m, m.openTreePicker()

	case TreeForkSuccessMsg:
		if m.State != AppStateTreePicker || msg.Generation != m.TreePicker.Generation {
			return m, nil
		}
		return m, m.setChatSession(msg.Session, true)

	case ChatOpenContextInspectorMsg:
		return m, m.openContextInspector()

	case ChatOpenCapabilityPageMsg:
		if m.ActiveSession != nil {
			m.CapabilityPage = NewCapabilityPageModel(m.Conn, m.ActiveSession.ID, msg.Kind)
			return m, m.openScreen(AppStateCapabilityPage, &m.CapabilityPage)
		}

	case ChatOpenPageMsg:
		if m.ActiveSession != nil {
			m.PageView = NewPageViewModel(m.Conn, m.ActiveSession.ID, msg.Command)
			return m, m.openScreen(AppStatePageView, &m.PageView)
		}

	case PageViewChangedMsg:
		m.Chat.statusRevision++
		return m, m.Chat.statusCmd()

	case ChatOpenLoginMsg:
		return m, m.openLogin(msg.Name)

	case LoginCancelMsg:
		cleanup := m.Login.Close()
		m.ProfileGen++
		// /login may have removed providers even when it ends without a choice.

		if m.StandaloneLogin {
			return m, tea.Batch(cleanup, tea.Quit)
		}
		if m.ActiveSession != nil {
			return m, tea.Batch(cleanup, m.returnToChat(), m.loadProfilesCmd("", m.ProfileGen))
		}
		m.State = AppStateSessionPicker
		m.updateSessionPickerItems()
		m.SessionGen++
		return m, tea.Batch(cleanup, m.SessionPicker.Init(), m.loadSessionsCmd(m.SessionGen))

	case LoginDoneMsg:
		if m.State != AppStateLogin || msg.Gen != m.Login.Generation {
			return m, nil
		}
		cleanup := m.Login.Close()
		m.ProfileGen++
		return m, tea.Batch(cleanup, m.loadProfilesCmd(msg.Name, m.ProfileGen))

	case PickerSelectMsg:
		if m.State == AppStateSessionPicker {
			switch msg.ID {
			case "new":
				return m, m.newSessionCmd()
			case "archive":
				m.SessionPicker.OpenArchive()
				return m, nil
			case "login":
				return m, m.openLogin("")
			default:
				// The active session may not yet appear in the daemon's recent list.
				listed := m.SessionPicker.raw
				if m.ActiveSession != nil && !slices.ContainsFunc(m.Sessions, func(s daemon.Session) bool { return s.ID == m.ActiveSession.ID }) {
					listed = append([]daemon.Session{*m.ActiveSession}, listed...)
				}
				if i := slices.IndexFunc(listed, func(s daemon.Session) bool { return s.ID == msg.ID }); i >= 0 {
					return m, m.openSession(listed[i])
				}
			}
		}

	case PickerCancelMsg:
		if m.State == AppStateSessionPicker {
			if m.SessionPicker.ArchiveView {
				m.SessionPicker.CloseArchive()
				return m, nil
			}
			if m.ActiveSession != nil {
				m.State = AppStateChat
				return m, nil
			}
			return m, tea.Quit
		}
	}

	// Route to active state model
	var cmd tea.Cmd
	switch m.State {
	case AppStateChat:
		beforePending := len(m.Chat.pendingUsers)
		before := m.Chat.Flags
		m.Chat, cmd = m.Chat.Update(msg)
		if len(m.Chat.pendingUsers) > beforePending {
			m.ClearNotices()
		}
		if m.Chat.Flags.Thinking != before.Thinking || m.Chat.Flags.Tools != before.Tools {
			draft := m.Chat.Flags
			m.Chat.Flags = before
			if !m.UISaving {
				m.UISaving = true
				m.SettingsGen++
				patch := daemon.UIPreferencesPatch{}
				if draft.Thinking != before.Thinking {
					patch.Thinking = &draft.Thinking
				}
				if draft.Tools != before.Tools {
					patch.Tools = &draft.Tools
				}
				cmd = tea.Batch(cmd, m.patchUICmd("", patch, m.SettingsGen))
			}
		}
	case AppStateSessionPicker:
		m.SessionPicker, cmd = m.SessionPicker.Update(msg)
	case AppStateModelPicker:
		m.ModelPicker, cmd = m.ModelPicker.Update(msg)
	case AppStateExtensionPicker:
		m.ExtensionPicker, cmd = m.ExtensionPicker.Update(msg)
	case AppStateTreePicker:
		m.TreePicker, cmd = m.TreePicker.Update(msg)
	case AppStateContextInspector:
		m.ContextInspector, cmd = m.ContextInspector.Update(msg)
	case AppStatePageView:
		m.PageView, cmd = m.PageView.Update(msg)
	case AppStateCapabilityPage:
		m.CapabilityPage, cmd = m.CapabilityPage.Update(msg)
	case AppStateWebhooksPage:
		m.WebhooksPage, cmd = m.WebhooksPage.Update(msg)
	case AppStateAgents:
		m.Agents, cmd = m.Agents.Update(msg)
	case AppStateFolderPicker:
		m.FolderPicker, cmd = m.FolderPicker.Update(msg)
	case AppStateLogin:
		m.Login, cmd = m.Login.Update(msg)
	}

	return m, cmd
}
