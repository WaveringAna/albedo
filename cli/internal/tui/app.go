// Package tui implements the interactive CLI and its terminal views.
package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"fmt"
	"maps"
	"slices"
	"strings"
	"time"

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

type sessionsLoadedMsg struct {
	Err      error
	Sessions []daemon.Session
	Gen      int
}

type sessionDeletedMsg struct {
	Err error
	ID  string
}

type sessionCreationRecoveryMsg struct {
	Handle *daemon.OperationHandle
	Gen    int
}

type sessionCreatedMsg struct {
	Handle  *daemon.OperationHandle
	Err     error
	Session daemon.Session
	Gen     int
}

type commandCatalogLoadedMsg struct {
	Err      error
	Commands []daemon.SessionCommand
	Gen      int
}

type modelChangedMsg struct {
	Selection *daemon.ModelSelection
	Err       error
	SessionID string
	Gen       int
}

type commandExecutedMsg struct {
	Err           error
	Name          string
	Message       string
	Effort        string
	SessionID     string
	Available     []string
	Gen           int
	EffortChanged bool
}

type glancesPolledMsg struct {
	Err     error
	Glances []PageGlance
	Gen     int
}

type glancePollTickMsg struct {
	SessionID string
	Gen       int
}

type profilesLoadedMsg struct {
	Profiles config.Profiles
	Err      error
	Provider string
	Gen      int
}

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
	Workspace        string
	Sessions         []daemon.Session
	Notices          Notices
	CommandCatalog   []daemon.SessionCommand
	Glances          []PageGlance
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
	GlanceRevision    int

	// SessionGen invalidates earlier session-list and session-creation replies.
	SessionGen int
	CatalogGen int
	ModelGen   int
	CommandGen int
	GlanceGen  int
	ProfileGen int
	// folderReturn is the screen the folder picker goes back to.
	folderReturn    AppState
	UISaving        bool
	StandaloneLogin bool

	// Graphemes says the terminal measures grapheme clusters; see ChatModel.
	Graphemes bool
}

// ApplyUI takes acknowledged shared preferences from the daemon.
func (m *AppModel) ApplyUI(prefs daemon.UIPreferences) {
	m.SessionPicker.prefs = sessionPrefs(prefs)
	m.SessionPicker.rebuild()
	m.Chat.Flags.Thinking, m.Chat.Flags.Tools = prefs.Thinking, prefs.Tools
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

func (m *AppModel) loadSessionsCmd(gen int) tea.Cmd {
	conn := m.Conn
	return func() tea.Msg {
		if conn == nil {
			return sessionsLoadedMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}
		sessions, err := daemon.ListSessions(context.Background(), conn)
		return sessionsLoadedMsg{Sessions: sessions, Err: err, Gen: gen}
	}
}

func (m *AppModel) renameSessionCmd(rename SessionRenameMsg) tea.Cmd {
	conn := m.Conn
	return func() tea.Msg {
		if conn == nil {
			return sessionRenamedMsg{SessionRenameMsg: rename, Err: errors.New("daemon connection unavailable")}
		}
		s, err := daemon.RenameSession(context.Background(), conn, rename.ID, rename.Name)
		return sessionRenamedMsg{SessionRenameMsg: rename, Session: s, Err: err}
	}
}

func (m *AppModel) deleteSessionCmd(id string) tea.Cmd {
	conn := m.Conn
	return func() tea.Msg {
		if conn == nil {
			return sessionDeletedMsg{ID: id, Err: errors.New("daemon connection unavailable")}
		}
		_, err := daemon.DeleteSession(context.Background(), conn, id, true)
		return sessionDeletedMsg{ID: id, Err: err}
	}
}

func sessionPreviewCmd(conn *daemon.Connection, id string) tea.Cmd {
	return func() tea.Msg {
		preview, err := daemon.GetSessionPreview(context.Background(), conn, id, 16)
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

func (m *AppModel) loadProfilesCmd(provider string, gen int) tea.Cmd {
	conn := m.Conn
	return func() tea.Msg {
		p, err := daemon.ProviderProfiles(context.Background(), conn)
		return profilesLoadedMsg{Profiles: p, Provider: provider, Err: err, Gen: gen}
	}
}

func (m *AppModel) loadCommandCatalogCmd(gen int) tea.Cmd {
	conn, hasSession := m.Conn, m.ActiveSession != nil
	var sessionID string
	if hasSession {
		sessionID = m.ActiveSession.ID
	}
	return func() tea.Msg {
		if conn == nil || !hasSession {
			return commandCatalogLoadedMsg{Gen: gen}
		}

		cmds, err := daemon.ListSessionCommands(context.Background(), conn, sessionID)
		return commandCatalogLoadedMsg{Commands: cmds, Err: err, Gen: gen}
	}
}

func (m *AppModel) changeModelCmd(model, provider, effort string, raiseCap *bool, gen int) tea.Cmd {
	conn, hasSession := m.Conn, m.ActiveSession != nil
	var sessionID, currentProvider string
	if hasSession {
		sessionID, currentProvider = m.ActiveSession.ID, m.ActiveSession.Provider
	}
	saveCap := raiseCap != nil
	var capEnabled bool
	if saveCap {
		capEnabled = *raiseCap
	}
	return func() tea.Msg {
		if conn == nil || !hasSession {
			return modelChangedMsg{Err: errors.New("no active session or connection"), SessionID: sessionID, Gen: gen}
		}

		selection, err := daemon.ChangeModel(context.Background(), conn, sessionID, daemon.ModelChangeRequest{Model: model, Provider: provider, Effort: effort, CurrentProvider: currentProvider})
		if err != nil {
			return modelChangedMsg{Err: err, SessionID: sessionID, Gen: gen}
		}
		changed := modelChangedMsg{Selection: &selection, SessionID: sessionID, Gen: gen}
		// Keep the confirmed switch if the following cap update fails.
		if saveCap {
			if err := daemon.SetModelContextCap(context.Background(), conn, sessionID, daemon.ModelContextCapRequest{Model: selection.Model, Enabled: capEnabled}); err != nil {
				changed.Err = fmt.Errorf("switched model; context cap update: %w", err)
				return changed
			}
		}

		return changed
	}
}

func (m *AppModel) executeCommandCmd(name, args string, gen int) tea.Cmd {
	conn, hasSession := m.Conn, m.ActiveSession != nil
	var sessionID string
	if hasSession {
		sessionID = m.ActiveSession.ID
	}
	return func() tea.Msg {
		if conn == nil || !hasSession {
			return commandExecutedMsg{Name: name, Err: errors.New("no active session or connection"), Gen: gen}
		}

		body := daemon.CommandRequest{Name: name, Arguments: args}

		res, err := daemon.ExecuteCommand(context.Background(), conn, sessionID, body)
		if err != nil {
			return commandExecutedMsg{Name: name, Err: err, Gen: gen}
		}

		msg := fmt.Sprintf("%s done", name)
		var newEffort string
		if res.Effort != nil {
			if args == "" {
				return commandExecutedMsg{Name: name, Available: res.Effort.Available, SessionID: sessionID, Gen: gen}
			}
			newEffort = res.Effort.Effort
			if res.Effort.Message != "" {
				msg = res.Effort.Message
			}
		} else if res.Message != "" {
			msg = res.Message
		}

		return commandExecutedMsg{Name: name, Message: msg, Effort: newEffort, EffortChanged: res.Effort != nil, SessionID: sessionID, Gen: gen}
	}
}

func (m AppModel) hasPageCommands() bool {
	return slices.ContainsFunc(m.CommandCatalog, func(cmd daemon.SessionCommand) bool {
		return cmd.Page != nil && *cmd.Page
	})
}

func glancePollTickCmd(sessionID string, gen int) tea.Cmd {
	return tea.Tick(3*time.Second, func(time.Time) tea.Msg {
		return glancePollTickMsg{SessionID: sessionID, Gen: gen}
	})
}

func (m *AppModel) pollGlancesCmd(gen int) tea.Cmd {
	conn, hasSession := m.Conn, m.ActiveSession != nil
	var sessionID string
	if hasSession {
		sessionID = m.ActiveSession.ID
	}
	var pageNames []string
	for _, cmd := range m.CommandCatalog {
		if cmd.Page != nil && *cmd.Page {
			pageNames = append(pageNames, cmd.Name)
		}
	}
	return func() tea.Msg {
		if conn == nil || !hasSession {
			return glancesPolledMsg{Gen: gen}
		}

		var glances []PageGlance
		for _, name := range pageNames {
			doc, err := daemon.LoadPage(context.Background(), conn, sessionID, name)
			if err != nil {
				return glancesPolledMsg{Gen: gen, Err: err}
			}
			if doc.Glance != nil {
				glances = append(glances, *doc.Glance)
			}
		}

		return glancesPolledMsg{Glances: glances, Gen: gen}
	}
}

func (m *AppModel) pollGlances() tea.Cmd {
	m.GlanceGen++
	cmds := []tea.Cmd{m.pollGlancesCmd(m.GlanceGen)}
	if m.ActiveSession != nil && m.hasPageCommands() {
		cmds = append(cmds, glancePollTickCmd(m.ActiveSession.ID, m.GlanceGen))
	}
	return tea.Batch(cmds...)
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
	m.GlanceGen++
	return tea.Batch(m.setChatSession(s, false), m.recordOpenCmd(s.ID))
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
	m.GlanceGen++
	return tea.Batch(m.SessionPicker.Init(), m.loadSessionsCmd(m.SessionGen), m.loadSettingsCmd(m.SettingsGen))
}

func (m *AppModel) newSessionCmd() tea.Cmd {
	m.SessionGen++
	return m.createSessionCmd(m.SessionGen, m.Workspace)
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
	m.FolderPicker = NewFolderPicker(daemonFolders{m.Conn}, *m.ActiveSession, retry)
	m.folderReturn = AppStateChat
	return m.openScreen(AppStateFolderPicker, &m.FolderPicker)
}

// openFolderBrowser lists sessions by folder, from the sessions view.
func (m *AppModel) openFolderBrowser(query string) tea.Cmd {
	m.FolderPicker = NewFolderBrowser(daemonFolders{m.Conn}, m.Workspace, query)
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
	m.ActiveSession.Workspace, m.ActiveSession.Location, m.Workspace = msg.Workspace, msg.Location, msg.Workspace
	if i := slices.IndexFunc(m.Sessions, func(s daemon.Session) bool { return s.ID == msg.SessionID }); i >= 0 {
		m.Sessions[i].Workspace, m.Sessions[i].Location = msg.Workspace, msg.Location
	}
	m.State = AppStateChat
	return m.Chat.Moved(daemon.Session{Workspace: msg.Workspace, Location: msg.Location}, msg.Retry)
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
	// First: forward chat lifecycle messages even while a modal is open.
	var sid string
	var forward bool
	switch sm := msg.(type) {
	case ChatOlderLoadedMsg:
		sid, forward = sm.SessionID, true
	case ChatWindowMsg:
		sid, forward = sm.SessionID, true
	case ChatEditorFinishedMsg:
		sid, forward = sm.SessionID, true
	case ChatClearCopyStatusMsg:
		sid, forward = sm.SessionID, true
	case ChatStatusPollMsg:
		sid, forward = sm.SessionID, true
	case ChatCacheFadeMsg:
		sid, forward = sm.SessionID, true
	case ChatProgressTickMsg:
		// a tick dropped under a modal would leave the face frozen for good
		sid, forward = sm.SessionID, true
	case ChatStatusMsg:
		sid, forward = sm.SessionID, true
	case ChatStreamResultMsg:
		sid, forward = sm.SessionID, true
	case ChatStreamClosedMsg:
		sid, forward = sm.SessionID, true
	case ChatInterruptMsg:
		sid, forward = sm.SessionID, true
	case ClipboardImagePastedMsg:
		sid, forward = sm.SessionID, true
	case ChatStreamEventMsg:
		sid, forward = sm.SessionID, true
		if m.ActiveSession != nil && sid == m.ActiveSession.ID && sm.Generation == m.Chat.Generation && sm.Event.Type == daemon.EventUser && !sm.Event.Replayed {
			m.ClearNotices()
		}
	case ChatOperationPollMsg:
		sid, forward = sm.SessionID, true
	case ChatOperationResolvedMsg:
		sid, forward = sm.SessionID, true
	case ChatTurnSentMsg:
		sid, forward = sm.SessionID, true
		if m.ActiveSession != nil && sid == m.ActiveSession.ID && sm.Err == nil {
			m.ClearNotices()
		}
	}
	if forward {
		var cmd tea.Cmd
		if m.ActiveSession != nil && sid == m.ActiveSession.ID {
			m.Chat, cmd = m.Chat.Update(msg)
		}
		if event, ok := msg.(ChatStreamEventMsg); ok && event.SessionID == m.Chat.SessionID && event.Generation == m.Chat.Generation && event.Event.Type == daemon.EventReset {
			cmd = tea.Batch(cmd, m.loadSettingsCmd(m.SettingsGen))
		}
		return m, cmd
	}

	switch msg := msg.(type) {
	case settingsLoadedMsg:
		if msg.Gen != m.SettingsGen {
			return m, nil
		}
		if msg.Err != nil {
			m.Chat.AddError(msg.Err.Error())
			m.SessionPicker.notice = msg.Err.Error()
			return m, nil
		}
		m.Profiles = msg.Settings.Profiles
		m.ApplyUI(msg.Settings.UI)
		return m, nil
	case uiSavedMsg:
		if msg.Open {
			if msg.Err != nil {
				m.Chat.AddError(msg.Err.Error())
				if _, uncertain := errors.AsType[*daemon.UncertainOutcomeError](msg.Err); uncertain {
					return m, nil
				}
			}
			return m, m.loadSettingsCmd(m.SettingsGen)
		}
		if msg.Gen != m.SettingsGen {
			return m, nil
		}
		m.UISaving, m.SessionPicker.Saving = false, false
		if msg.Err != nil {
			m.Chat.AddError(msg.Err.Error())
			m.SessionPicker.notice = msg.Err.Error()
			return m, nil
		}
		m.SessionPicker.notice = ""
		m.ApplyUI(msg.Prefs)
		return m, nil
	case SessionPreferenceMsg:
		if m.UISaving {
			m.SessionPicker.Saving = false
			return m, nil
		}
		m.UISaving = true
		m.SettingsGen++
		patch := daemon.UIPreferencesPatch{}
		switch msg.Field {
		case "pinned":
			patch.Pinned = &msg.Value
		case "archived":
			patch.Archived = &msg.Value
		}
		return m, m.patchUICmd(msg.ID, patch, m.SettingsGen)

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

	case sessionDeletedMsg:
		if msg.Err == nil {
			delete(m.pendingBySession, msg.ID)
		}
		if msg.Err != nil {
			m.AddError(operationError(msg.Err, "Could not delete the session: ", "Session may have been deleted; refresh the session list before trying again."))
			return m, nil
		}
		m.SessionPicker.Removed(msg.ID)
		m.Sessions = slices.DeleteFunc(m.Sessions, func(s daemon.Session) bool { return s.ID == msg.ID })
		m.ClearNotices()
		return m, nil

	case SessionRenameMsg:
		return m, m.renameSessionCmd(msg)

	// Every screen listing the session hears the answer; the agents view
	// also gets the new name from the daemon's agents stream.
	case sessionRenamedMsg:
		var cmd tea.Cmd
		if m.State == AppStateAgents {
			m.Agents, cmd = m.Agents.Update(msg)
		}
		if msg.Err != nil {
			m.SessionPicker.notice = operationError(msg.Err, "Could not rename the session: ", "Session may have been renamed; refresh the session list before trying again.")
			return m, cmd
		}
		if i := slices.IndexFunc(m.Sessions, func(s daemon.Session) bool { return s.ID == msg.ID }); i >= 0 {
			m.Sessions[i] = msg.Session
		}
		if m.ActiveSession != nil && m.ActiveSession.ID == msg.ID {
			m.ActiveSession.Title = msg.Session.Title
		}
		m.SessionPicker.notice = ""
		m.SessionPicker.Renamed(msg.Session)
		return m, cmd

	case SessionDeleteMsg:
		if m.State != AppStateSessionPicker || !m.SessionPicker.ArchiveView || m.ActiveSession != nil && m.ActiveSession.ID == msg.ID {
			return m, nil
		}
		return m, m.deleteSessionCmd(msg.ID)

	case sessionsLoadedMsg:
		if msg.Gen != m.SessionGen {
			return m, nil
		}
		if msg.Err != nil {
			m.SessionPicker.Loading = false
			m.AddError("Could not load sessions: " + msg.Err.Error())
			return m, nil
		}
		m.Sessions = msg.Sessions
		m.ClearNotices()
		m.SessionPicker.Prune(msg.Sessions)
		m.updateSessionPickerItems()
		return m, m.SessionPicker.PreviewCmd()

	case sessionCreationRecoveryMsg:
		if pending, exists := m.pendingCreations[msg.Handle.ID()]; !exists || pending.Expired {
			return m, nil
		}
		conn, handle, gen := m.Conn, msg.Handle, msg.Gen
		return m, func() tea.Msg {
			session, err := daemon.ResolveCreation(context.Background(), conn, handle)
			return sessionCreatedMsg{Session: session, Err: err, Handle: handle, Gen: gen}
		}

	case sessionCreatedMsg:
		if msg.Gen != m.SessionGen && (msg.Handle == nil || m.pendingCreations[msg.Handle.ID()].Handle == nil) {
			return m, nil
		}
		if msg.Handle != nil && daemon.IsOperationExpired(msg.Err) {
			pending := m.pendingCreations[msg.Handle.ID()]
			pending.Expired = true
			m.pendingCreations[msg.Handle.ID()] = pending
			m.AddError("Session operation " + msg.Handle.ID() + " expired; its outcome is unresolved.")
			return m, nil
		}
		if msg.Err != nil && msg.Handle != nil {
			if _, uncertain := errors.AsType[*daemon.UncertainOutcomeError](msg.Err); uncertain {
				m.AddError("Session admission is uncertain. Checking operation " + msg.Handle.ID() + ".")
				return m, creationRecoveryCmd(msg.Handle, msg.Gen)
			}
			if api, ok := errors.AsType[*daemon.APIError](msg.Err); ok && (api.Code == "operation_unknown" || api.StatusCode >= 500) {
				return m, creationRecoveryCmd(msg.Handle, msg.Gen)
			}
		}
		if msg.Handle != nil {
			delete(m.pendingCreations, msg.Handle.ID())
		}
		if msg.Gen != m.SessionGen {
			if msg.Err != nil {
				m.AddError(msg.Err.Error())
				return m, nil
			}
			if !slices.ContainsFunc(m.Sessions, func(session daemon.Session) bool { return session.ID == msg.Session.ID }) {
				m.Sessions = append(m.Sessions, msg.Session)
			}
			m.updateSessionPickerItems()
			m.ClearNotices()
			m.AddNotice("Recovered the created session " + msg.Session.ID)
			return m, nil
		}
		if msg.Err != nil && m.State == AppStateFolderPicker {
			m.FolderPicker.Refused(errors.New(operationError(msg.Err, "", "Session may have been created; check the session list before creating another.")))
			return m, nil
		}
		if msg.Err != nil {
			m.AddError(operationError(msg.Err, "Could not create a session: ", "Session may have been created; check the session list before creating another."))
			return m, nil
		}
		return m, m.setChatSession(msg.Session, true)

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
		return m, m.pollGlances()

	case glancePollTickMsg:
		if m.ActiveSession == nil || msg.SessionID != m.ActiveSession.ID || msg.Gen != m.GlanceGen || !m.hasPageCommands() {
			return m, nil
		}
		return m, tea.Batch(
			m.pollGlancesCmd(m.GlanceGen),
			glancePollTickCmd(m.ActiveSession.ID, m.GlanceGen),
		)

	case modelChangedMsg:
		if msg.Gen != m.ModelGen || m.ActiveSession == nil || msg.SessionID != m.ActiveSession.ID {
			return m, nil
		}
		if msg.Selection != nil {
			selected := msg.Selection
			m.ActiveSession.Model, m.Chat.Model = selected.Model, selected.Model
			m.ActiveSession.Effort, m.Chat.Effort = selected.Effort, selected.Effort
			m.ActiveSession.Provider, m.Chat.Provider = selected.Provider, selected.Provider
			m.ActiveSession.Protocol = selected.Protocol
			m.ModelPicker.Saving = false
			if m.State == AppStateModelPicker {
				m.State = AppStateChat
			}
			m.ClearNotices()
		}
		if msg.Err != nil {
			message := operationError(msg.Err, "Model settings error: ", "Model settings may have changed; check them before trying again.")
			if m.State == AppStateModelPicker {
				m.ModelPicker.Saving = false
				m.ModelPicker.Error = message
			} else {
				m.AddError(message)
			}
		}
		return m, nil

	case commandExecutedMsg:
		if msg.Gen != m.CommandGen || (msg.SessionID != "" && (m.ActiveSession == nil || msg.SessionID != m.ActiveSession.ID)) {
			return m, nil
		}
		m.ClearNotices()
		if len(msg.Available) > 0 && m.State == AppStateChat {
			m.Chat.openEffortSelector(msg.Available)
			return m, nil
		}
		if msg.Err != nil {
			m.AddError(operationError(msg.Err, "Command error: ", msg.Name+" may have run; check its result before running it again."))
			return m, nil
		}
		m.AddNotice(msg.Message)
		if msg.EffortChanged && m.ActiveSession != nil {
			m.ActiveSession.Effort = msg.Effort
			m.Chat.Effort = msg.Effort
		}
		return m, nil

	case glancesPolledMsg:
		if msg.Err != nil {
			return m, nil
		}
		if msg.Gen == m.GlanceGen {
			m.Glances = msg.Glances
			m.Chat.Glances = msg.Glances
			m.Chat.SetSize(m.Width, m.Height)
		}
		return m, nil

	case profilesLoadedMsg:
		if msg.Gen != m.ProfileGen {
			return m, nil
		}
		m.ClearNotices()
		if msg.Err != nil {
			m.AddError("Could not load providers: " + msg.Err.Error())
		} else {
			m.Profiles = msg.Profiles
			notice := fmt.Sprintf("%s selected for new sessions", msg.Provider)
			if m.ActiveSession != nil {
				notice += fmt.Sprintf("; use /model to switch this session from %s", m.ActiveSession.Provider)
			}
			m.AddNotice(notice)
		}
		if m.StandaloneLogin {
			return m, tea.Quit
		}
		if msg.Err == nil && m.ActiveSession == nil && len(m.Sessions) == 0 {
			return m, m.newSessionCmd()
		}
		if m.ActiveSession == nil {
			m.State = AppStateSessionPicker
			m.updateSessionPickerItems()
			return m, nil
		}
		return m, m.returnToChat()

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
		m.ModelPicker.Saving = true
		m.ModelPicker.Error = ""
		m.ModelGen++
		return m, m.changeModelCmd(msg.Model, msg.Provider, msg.Effort, msg.RaiseCap, m.ModelGen)

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
			m.Agents = NewAgentsViewModel(m.Conn, m.ActiveSession.ID)
			return m, m.openScreen(AppStateAgents, &m.Agents)
		}

	case ChatOpenFolderPickerMsg:
		return m, m.openFolderPicker(msg.Retry)

	case FolderMovedMsg:
		return m, m.moved(msg)

	case FolderPickerCancelMsg:
		m.State = m.folderReturn
		return m, nil

	case SessionFoldersMsg:
		return m, m.openFolderBrowser(msg.Query)

	case FolderOpenSessionMsg:
		return m, m.openSession(msg.Session)

	case FolderNewSessionMsg:
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

	case ModelPickerCancelMsg, WebhooksPageDoneMsg, ExtensionPickerDoneMsg,
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
		m.GlanceRevision++
		return m, m.pollGlances()

	case ChatOpenLoginMsg:
		return m, m.openLogin(msg.Name)

	case LoginCancelMsg:
		m.ProfileGen++
		// /login may have removed providers even when it ends without a choice.

		if m.StandaloneLogin {
			return m, tea.Quit
		}
		if m.ActiveSession != nil {
			return m, tea.Batch(m.returnToChat(), m.loadProfilesCmd("", m.ProfileGen))
		}
		m.State = AppStateSessionPicker
		m.updateSessionPickerItems()
		m.SessionGen++
		return m, tea.Batch(m.SessionPicker.Init(), m.loadSessionsCmd(m.SessionGen))

	case LoginDoneMsg:
		if m.State != AppStateLogin {
			return m, nil
		}
		m.ProfileGen++
		return m, m.loadProfilesCmd(msg.Name, m.ProfileGen)

	case ChatExecuteCommandMsg:
		if slices.ContainsFunc(m.CommandCatalog, func(command daemon.SessionCommand) bool { return command.Name == msg.Name && command.Skill }) {
			var commands []tea.Cmd
			m.Chat.handleSubmittedCommand(strings.TrimSpace(msg.Name+" "+msg.Args), &commands)
			return m, tea.Batch(commands...)
		}
		switch msg.Name {
		case "/login":
			return m, m.openLogin(msg.Args)
		case "/model":
			if msg.Args != "" {
				m.ModelGen++
				return m, m.changeModelCmd(msg.Args, "", "", nil, m.ModelGen)
			}
			return m, m.openModelPicker()
		case "/new":
			return m, m.newSessionCmd()
		case "/agents":
			return m, func() tea.Msg { return ChatOpenAgentsMsg{} }
		case "/sessions", "/a":
			return m, m.openSessions()
		case "/extensions", "/plugins":
			return m, m.openExtensionPicker()
		case "/tree":
			return m, m.openTreePicker()
		case "/cd":
			if msg.Args == "" || m.ActiveSession == nil {
				return m, m.openFolderPicker(nil)
			}
			return m, moveCmd(daemonFolders{m.Conn}, m.ActiveSession.ID, m.ActiveSession.Workspace, msg.Args, nil)
		case "/context":
			return m, m.openContextInspector()
		default:
			m.CommandGen++
			return m, m.executeCommandCmd(msg.Name, msg.Args, m.CommandGen)
		}

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
				listed := m.Sessions
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

// View captures the mouse only in chat, where it scrolls and selects; every
// other screen leaves it to the terminal.
func (m AppModel) View() tea.View {
	v := tea.NewView(m.content())
	v.MouseMode = tea.MouseModeNone
	if m.State == AppStateChat {
		v.MouseMode = tea.MouseModeCellMotion
	}
	return v
}

func (m AppModel) content() string {
	switch m.State {
	case AppStateChat:
		return m.Chat.View()
	case AppStateSessionPicker:
		var b strings.Builder
		for _, n := range m.Notices {
			style := DefaultStyles.Faint
			if n.Error {
				style = DefaultStyles.Error
			}
			b.WriteString(style.Render(n.Message))
			b.WriteByte('\n')
		}
		return b.String() + m.SessionPicker.View()
	case AppStateModelPicker:
		return m.ModelPicker.View()
	case AppStateExtensionPicker:
		return m.ExtensionPicker.View()
	case AppStateTreePicker:
		return m.TreePicker.View()
	case AppStateContextInspector:
		return m.ContextInspector.View()
	case AppStatePageView:
		return m.PageView.View()
	case AppStateCapabilityPage:
		return m.CapabilityPage.View()
	case AppStateWebhooksPage:
		return m.WebhooksPage.View()
	case AppStateAgents:
		return m.Agents.View()
	case AppStateFolderPicker:
		return m.FolderPicker.View()
	case AppStateLogin:
		return m.Login.View()
	default:
		return ""
	}
}

type settingsLoadedMsg struct {
	Err      error
	Settings daemon.Settings
	Gen      int
}
type uiSavedMsg struct {
	Err   error
	Prefs daemon.UIPreferences
	Gen   int
	Open  bool
}

func (m *AppModel) loadSettingsCmd(gen int) tea.Cmd {
	if m.UISaving {
		return nil
	}
	conn := m.Conn
	return func() tea.Msg {
		settings, err := daemon.GetSettings(context.Background(), conn)
		return settingsLoadedMsg{Settings: settings, Gen: gen, Err: err}
	}
}

func (m *AppModel) patchUICmd(session string, patch daemon.UIPreferencesPatch, gen int) tea.Cmd {
	conn := m.Conn
	if patch.Thinking != nil {
		patch.Thinking = new(*patch.Thinking)
	}
	if patch.Tools != nil {
		patch.Tools = new(*patch.Tools)
	}
	if patch.Pinned != nil {
		patch.Pinned = new(*patch.Pinned)
	}
	if patch.Archived != nil {
		patch.Archived = new(*patch.Archived)
	}
	return func() tea.Msg {
		var prefs daemon.UIPreferences
		var err error
		if session == "" {
			prefs, err = daemon.PatchUI(context.Background(), conn, patch)
		} else {
			prefs, err = daemon.PatchSessionUI(context.Background(), conn, session, patch)
		}
		return uiSavedMsg{Prefs: prefs, Gen: gen, Err: err}
	}
}

func (m *AppModel) recordOpenCmd(session string) tea.Cmd {
	conn := m.Conn
	return func() tea.Msg {
		prefs, err := daemon.RecordOpen(context.Background(), conn, session)
		return uiSavedMsg{Prefs: prefs, Open: true, Err: err}
	}
}
