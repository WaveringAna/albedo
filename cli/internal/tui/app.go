package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
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
)

type sessionsLoadedMsg struct {
	Sessions []daemon.Session
	Err      error
	Gen      int
}

type sessionDeletedMsg struct {
	ID  string
	Err error
}

type sessionCreatedMsg struct {
	Session daemon.Session
	Err     error
	Gen     int
}

type commandCatalogLoadedMsg struct {
	Commands []daemon.SessionCommand
	Err      error
	Gen      int
}

type modelChangedMsg struct {
	Model    string
	Provider string
	Protocol string
	Effort   string
	Err      error
	Gen      int
}

type commandExecutedMsg struct {
	Name    string
	Message string
	Effort  string
	Err     error
	Gen     int
}

type ChatWorkspaceChangedMsg struct {
	SessionID string
	Workspace string
}

type glancesPolledMsg struct {
	Glances []PageGlance
	Err     error
	Gen     int
}

type glancePollTickMsg struct {
	SessionID string
	Gen       int
}

type profilesLoadedMsg struct {
	Profiles config.Profiles
	Provider string
	Err      error
	Gen      int
}

type AppModel struct {
	Conn              *daemon.Connection
	Profiles          config.Profiles
	State             AppState
	ActiveSession     *daemon.Session
	Sessions          []daemon.Session
	Workspace         string
	Width             int
	Height            int
	Notices           Notices
	CommandCatalog    []daemon.SessionCommand
	Glances           []PageGlance
	ExtensionRevision int
	GlanceRevision    int
	StandaloneLogin   bool
	BrowserOpener     func(url string)

	// Independent generation counters for concurrent async tasks
	SessionGen int
	CatalogGen int
	ModelGen   int
	CommandGen int
	GlanceGen  int
	ProfileGen int

	// Sub-models
	Chat             ChatModel
	SessionPicker    SessionViewer
	ModelPicker      ModelPickerModel
	ExtensionPicker  ExtensionPickerModel
	TreePicker       TreePickerModel
	ContextInspector ContextInspectorModel
	PageView         PageViewModel
	Login            LoginModel
	CapabilityPage   CapabilityPageModel
	WebhooksPage     WebhooksPageModel
}

// LoadPrefs applies the same display choices to the initial and future chats.
func (m *AppModel) LoadPrefs(path string) {
	m.SessionPicker.LoadPrefs(path)
	m.Chat.Flags.Thinking = m.SessionPicker.prefs.Thinking
	m.Chat.Flags.Tools = m.SessionPicker.prefs.Tools
}

func (m *AppModel) newChatModel(session *daemon.Session) ChatModel {
	chat := NewChatModel(session, m.newChatClient(session.ID))
	chat.Flags.Thinking = m.SessionPicker.prefs.Thinking
	chat.Flags.Tools = m.SessionPicker.prefs.Tools
	chat.Notices = append(Notices(nil), m.Notices...)
	m.Notices = nil
	return chat
}

func (m AppModel) newChatClient(sessionID string) *daemon.ChatClient {
	return daemon.NewChatClient(daemon.ChatClientOptions{
		AgentID: sessionID,
		Conn:    m.Conn,
	})
}

func NewAppModel(conn *daemon.Connection, profiles config.Profiles, initialSession *daemon.Session, workspace string, needsLogin bool) AppModel {
	if conn != nil && conn.HomeDir() == "" {
		conn.SetHomeDir(config.HomeDir())
	}
	if conn == nil {
		if existing, _ := daemon.Existing(config.HomeDir()); existing != nil {
			conn = existing
		}
	}
	m := AppModel{
		Conn:          conn,
		Profiles:      profiles,
		ActiveSession: initialSession,
		Workspace:     workspace,
	}

	if needsLogin {
		m.State = AppStateLogin
		m.Login = NewLoginModel(conn, "")
		m.Login.BrowserOpener = m.BrowserOpener
	} else if initialSession != nil {
		m.State = AppStateChat
		m.Chat = m.newChatModel(initialSession)
	} else {
		m.State = AppStateSessionPicker
	}
	// Built even when starting in a session so /sessions has a working search.
	m.SessionPicker = NewSessionViewer(workspace)
	if conn != nil {
		m.SessionPicker.Fetch = m.sessionPreviewCmd
	}

	return m
}

func (m AppModel) Init() tea.Cmd {
	m.Login.BrowserOpener = m.BrowserOpener
	switch m.State {
	case AppStateChat:
		return tea.Batch(
			m.Chat.Init(),
			m.loadCommandCatalogCmd(m.CatalogGen),
			mouseModeCmd(AppStateChat),
		)
	case AppStateLogin:
		m.Login.BrowserOpener = m.BrowserOpener
		if !m.StandaloneLogin && m.ActiveSession == nil {
			return tea.Batch(m.Login.Init(), m.loadSessionsCmd(m.SessionGen))
		}
		return m.Login.Init()
	case AppStateSessionPicker:
		return tea.Batch(
			m.SessionPicker.Init(),
			m.loadSessionsCmd(m.SessionGen),
		)
	}
	return nil
}

func (m AppModel) loadSessionsCmd(gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return sessionsLoadedMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}
		sessions, err := daemon.Request[[]daemon.Session](context.Background(), m.Conn, "/sessions", nil)
		return sessionsLoadedMsg{Sessions: sessions, Err: err, Gen: gen}
	}
}

func (m AppModel) deleteSessionCmd(id string) tea.Cmd {
	conn := m.Conn
	return func() tea.Msg {
		if conn == nil {
			return sessionDeletedMsg{ID: id, Err: errors.New("daemon connection unavailable")}
		}
		_, err := daemon.RequestMethod[struct{}](context.Background(), conn, http.MethodDelete, "/sessions/"+url.PathEscape(id), nil)
		return sessionDeletedMsg{ID: id, Err: err}
	}
}

func (m AppModel) sessionPreviewCmd(id string) tea.Cmd {
	conn := m.Conn
	return func() tea.Msg {
		preview, err := daemon.Request[SessionPreview](context.Background(), conn, "/sessions/"+url.PathEscape(id)+"/preview?limit=16", nil)
		return SessionPreviewMsg{ID: id, Preview: preview, Err: err}
	}
}

func (m AppModel) createSessionCmd(gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return sessionCreatedMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}
		body := map[string]string{"workspace": m.Workspace}
		s, err := daemon.Request[daemon.Session](context.Background(), m.Conn, "/sessions", body)
		return sessionCreatedMsg{Session: s, Err: err, Gen: gen}
	}
}

func (m AppModel) loadProfilesCmd(provider string, gen int) tea.Cmd {
	return func() tea.Msg {
		home := config.HomeDir()
		p, err := config.LoadProfiles(home)
		return profilesLoadedMsg{
			Profiles: p,
			Provider: provider,
			Err:      err,
			Gen:      gen,
		}
	}
}

func (m AppModel) loadCommandCatalogCmd(gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil || m.ActiveSession == nil {
			return commandCatalogLoadedMsg{Gen: gen}
		}

		health, err := daemon.Request[struct {
			Capabilities []string `json:"capabilities"`
		}](context.Background(), m.Conn, "/health", nil)
		if err == nil {
			hasCap := false
			for _, c := range health.Capabilities {
				if c == "session_commands" {
					hasCap = true
					break
				}
			}
			if !hasCap {
				return commandCatalogLoadedMsg{
					Err: errors.New("daemon upgrade needed for the command menu; when ready, run albedo daemon --stop, then albedo (this clears python variables)"),
					Gen: gen,
				}
			}
		}

		path := fmt.Sprintf("/sessions/%s/commands", url.PathEscape(m.ActiveSession.ID))
		raw, err := daemon.Request[any](context.Background(), m.Conn, path, nil)
		if err != nil {
			return commandCatalogLoadedMsg{Err: err, Gen: gen}
		}

		rawBytes, err := json.Marshal(raw)
		if err != nil {
			return commandCatalogLoadedMsg{Err: err, Gen: gen}
		}

		cmds, err := daemon.ParseCommandCatalog(rawBytes)
		return commandCatalogLoadedMsg{Commands: cmds, Err: err, Gen: gen}
	}
}

func (m AppModel) changeModelCmd(model, provider string, gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil || m.ActiveSession == nil {
			return modelChangedMsg{Err: errors.New("no active session or connection"), Gen: gen}
		}

		if provider != "" && provider != m.ActiveSession.Provider {
			health, err := daemon.Request[struct {
				Capabilities []string `json:"capabilities"`
			}](context.Background(), m.Conn, "/health", nil)
			if err == nil {
				hasCap := false
				for _, c := range health.Capabilities {
					if c == "session_provider" {
						hasCap = true
						break
					}
				}
				if !hasCap {
					return modelChangedMsg{
						Err: errors.New("daemon upgrade needed to switch providers; when ready, run albedo daemon --stop, then albedo (this clears python variables)"),
						Gen: gen,
					}
				}
			}
		}

		path := fmt.Sprintf("/sessions/%s/commands", url.PathEscape(m.ActiveSession.ID))
		args := map[string]string{"model": model}
		if provider != "" {
			args["provider"] = provider
		}
		body := map[string]any{
			"name": "/model",
			"args": args,
		}

		res, err := daemon.Request[map[string]any](context.Background(), m.Conn, path, body)
		if err != nil {
			return modelChangedMsg{Err: err, Gen: gen}
		}

		newModel := model
		newProvider := provider
		var newProtocol string
		var newEffort string

		if r, ok := res["result"].(map[string]any); ok {
			if mVal, ok := r["model"].(string); ok && mVal != "" {
				newModel = mVal
			}
			if pVal, ok := r["provider"].(string); ok && pVal != "" {
				newProvider = pVal
			}
			if protoVal, ok := r["protocol"].(string); ok && protoVal != "" {
				newProtocol = protoVal
			}
			if eVal, ok := r["effort"].(string); ok {
				newEffort = eVal
			}
		}

		return modelChangedMsg{
			Model:    newModel,
			Provider: newProvider,
			Protocol: newProtocol,
			Effort:   newEffort,
			Gen:      gen,
		}
	}
}

func (m AppModel) executeCommandCmd(name, args string, gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil || m.ActiveSession == nil {
			return commandExecutedMsg{Name: name, Err: errors.New("no active session or connection"), Gen: gen}
		}

		path := fmt.Sprintf("/sessions/%s/commands", url.PathEscape(m.ActiveSession.ID))
		body := map[string]any{
			"name": name,
		}
		if args != "" {
			body["arguments"] = args
		}

		res, err := daemon.Request[map[string]any](context.Background(), m.Conn, path, body)
		if err != nil {
			return commandExecutedMsg{Name: name, Err: err, Gen: gen}
		}

		msg := fmt.Sprintf("%s done", name)
		var newEffort string
		if res != nil {
			if r, ok := res["result"].(map[string]any); ok {
				if eStr, ok := r["effort"].(string); ok {
					newEffort = eStr
				}
				if mStr, ok := r["message"].(string); ok && mStr != "" {
					msg = mStr
				}
			} else if mStr, ok := res["message"].(string); ok && mStr != "" {
				msg = mStr
			}
		}

		return commandExecutedMsg{Name: name, Message: msg, Effort: newEffort, Gen: gen}
	}
}

func (m AppModel) hasPageCommands() bool {
	for _, cmd := range m.CommandCatalog {
		if cmd.Page != nil && *cmd.Page {
			return true
		}
	}
	return false
}

func glancePollTickCmd(sessionID string, gen int) tea.Cmd {
	return tea.Tick(3*time.Second, func(t time.Time) tea.Msg {
		return glancePollTickMsg{
			SessionID: sessionID,
			Gen:       gen,
		}
	})
}

func (m AppModel) pollGlancesCmd(gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil || m.ActiveSession == nil {
			return glancesPolledMsg{Gen: gen}
		}

		var pageCmds []string
		for _, cmd := range m.CommandCatalog {
			if cmd.Page != nil && *cmd.Page {
				pageCmds = append(pageCmds, cmd.Name)
			}
		}
		if len(pageCmds) == 0 {
			return glancesPolledMsg{Gen: gen}
		}

		var glances []PageGlance
		for _, name := range pageCmds {
			path := fmt.Sprintf("/sessions/%s/commands", url.PathEscape(m.ActiveSession.ID))
			body := map[string]any{"name": name, "args": map[string]string{}}
			res, err := daemon.Request[map[string]any](context.Background(), m.Conn, path, body)
			if err == nil {
				var target any = res
				if r, ok := res["result"]; ok && r != nil {
					target = r
				}
				doc, err := parsePageDocument(target)
				if err == nil && doc != nil && doc.Glance != nil {
					glances = append(glances, *doc.Glance)
				}
			}
		}

		return glancesPolledMsg{Glances: glances, Gen: gen}
	}
}

func (m *AppModel) updateSessionPickerItems() {
	m.SessionPicker.SetSessions(m.Sessions, m.ActiveSession)
}

func mouseModeCmd(state AppState) tea.Cmd {
	return func() tea.Msg {
		if state == AppStateChat {
			return tea.EnableMouseCellMotion()
		}
		return tea.DisableMouse()
	}
}

func (m *AppModel) AddNotice(message string) {
	if m.ActiveSession != nil {
		m.Chat.AddNotice(message)
		return
	}
	m.Notices.AddNotice(message)
}

func (m *AppModel) AddError(message string) {
	if m.ActiveSession != nil {
		m.Chat.AddError(message)
		return
	}
	m.Notices.AddError(message)
}

func (m *AppModel) ClearNotices() {
	m.Notices.Clear()
	if m.ActiveSession != nil {
		m.Chat.ClearNotices()
	}
}

func (m AppModel) Update(msg tea.Msg) (result tea.Model, command tea.Cmd) {
	previous := m.State
	defer func() {
		updated, ok := result.(AppModel)
		if !ok {
			return
		}
		result = updated
		if updated.State != previous {
			command = tea.Batch(command, mouseModeCmd(updated.State))
		}
	}()
	// First: forward chat lifecycle messages even while a modal is open.
	switch streamMsg := msg.(type) {
	case ChatEditorFinishedMsg:
		var cmd tea.Cmd
		if m.ActiveSession != nil && streamMsg.SessionID == m.ActiveSession.ID {
			m.Chat, cmd = m.Chat.Update(msg)
		}
		return m, cmd
	case ChatClearCopyStatusMsg:
		var cmd tea.Cmd
		if m.ActiveSession != nil && streamMsg.SessionID == m.ActiveSession.ID {
			m.Chat, cmd = m.Chat.Update(msg)
		}
		return m, cmd
	case ChatStatusPollMsg:
		var cmd tea.Cmd
		if m.ActiveSession != nil && streamMsg.SessionID == m.ActiveSession.ID {
			m.Chat, cmd = m.Chat.Update(msg)
		}
		return m, cmd
	case ChatStatusMsg:
		var cmd tea.Cmd
		if m.ActiveSession != nil && streamMsg.SessionID == m.ActiveSession.ID {
			m.Chat, cmd = m.Chat.Update(msg)
		}
		return m, cmd
	case ChatStreamEventMsg:
		var cmd tea.Cmd
		if m.ActiveSession != nil && streamMsg.SessionID == m.ActiveSession.ID {
			if streamMsg.Event.Type == daemon.EventUser && !streamMsg.Event.Replayed {
				m.ClearNotices()
			}
			m.Chat, cmd = m.Chat.Update(msg)
		}
		return m, cmd
	case ChatStreamClosedMsg:
		var cmd tea.Cmd
		if m.ActiveSession != nil && streamMsg.SessionID == m.ActiveSession.ID {
			m.Chat, cmd = m.Chat.Update(msg)
		}
		return m, cmd
	case ChatTurnSentMsg:
		var cmd tea.Cmd
		if m.ActiveSession != nil && streamMsg.SessionID == m.ActiveSession.ID {
			if streamMsg.Err == nil {
				m.ClearNotices()
			}
			m.Chat, cmd = m.Chat.Update(msg)
		}
		return m, cmd
	case ChatInterruptMsg:
		var cmd tea.Cmd
		if m.ActiveSession != nil && streamMsg.SessionID == m.ActiveSession.ID {
			m.Chat, cmd = m.Chat.Update(msg)
		}
		return m, cmd
	case ClipboardImagePastedMsg:
		var cmd tea.Cmd
		if m.ActiveSession != nil && streamMsg.SessionID == m.ActiveSession.ID {
			m.Chat, cmd = m.Chat.Update(msg)
		}
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
		m.Login.SetSize(msg.Width, msg.Height)
		return m, nil

	case ChatWorkspaceChangedMsg:
		if m.ActiveSession != nil && (msg.SessionID == "" || msg.SessionID == m.ActiveSession.ID) {
			m.ActiveSession.Workspace = msg.Workspace
			m.Workspace = msg.Workspace
			for i := range m.Sessions {
				if m.Sessions[i].ID == m.ActiveSession.ID {
					m.Sessions[i].Workspace = msg.Workspace
					break
				}
			}
		}
		return m, nil

	case sessionDeletedMsg:
		if msg.Err != nil {
			m.AddError("Could not delete session: " + msg.Err.Error())
			return m, nil
		}
		m.SessionPicker.Removed(msg.ID)
		for i, session := range m.Sessions {
			if session.ID == msg.ID {
				m.Sessions = append(m.Sessions[:i], m.Sessions[i+1:]...)
				break
			}
		}
		m.ClearNotices()
		return m, nil

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
			m.AddError("Error: " + msg.Err.Error())
		} else {
			m.Sessions = msg.Sessions
			m.ClearNotices()
			m.SessionPicker.Prune(msg.Sessions)
			m.updateSessionPickerItems()
			return m, m.SessionPicker.PreviewCmd()
		}
		return m, nil

	case sessionCreatedMsg:
		if msg.Gen != m.SessionGen {
			return m, nil
		}
		if msg.Err != nil {
			m.AddError("Error: " + msg.Err.Error())
			return m, nil
		}
		m.Chat.Close()
		s := msg.Session
		m.ActiveSession = &s
		m.Sessions = append([]daemon.Session{s}, m.Sessions...)
		m.Chat = m.newChatModel(&s)
		m.Chat.SetSize(m.Width, m.Height)
		m.State = AppStateChat
		m.CatalogGen++
		return m, tea.Batch(
			m.Chat.Init(),
			m.loadCommandCatalogCmd(m.CatalogGen),
		)

	case commandCatalogLoadedMsg:
		if msg.Gen != m.CatalogGen {
			return m, nil
		}
		if msg.Err != nil {
			if strings.Contains(msg.Err.Error(), "daemon upgrade") {
				m.AddError("Error: " + msg.Err.Error())
				if m.ActiveSession != nil {
				}
			}
		} else {
			m.CommandCatalog = msg.Commands
			m.Chat.CommandMenu.Catalog = msg.Commands
			m.GlanceGen++
			var cmds []tea.Cmd
			cmds = append(cmds, m.pollGlancesCmd(m.GlanceGen))
			if m.ActiveSession != nil && m.hasPageCommands() {
				cmds = append(cmds, glancePollTickCmd(m.ActiveSession.ID, m.GlanceGen))
			}
			return m, tea.Batch(cmds...)
		}
		return m, nil

	case glancePollTickMsg:
		if m.ActiveSession == nil || msg.SessionID != m.ActiveSession.ID || msg.Gen != m.GlanceGen {
			return m, nil // Obsolete tick dropped
		}
		if !m.hasPageCommands() {
			return m, nil
		}
		return m, tea.Batch(
			m.pollGlancesCmd(m.GlanceGen),
			glancePollTickCmd(m.ActiveSession.ID, m.GlanceGen),
		)

	case modelChangedMsg:
		if msg.Gen != m.ModelGen {
			return m, nil
		}
		if msg.Err != nil {
			if m.State == AppStateModelPicker {
				m.ModelPicker.Saving = false
				m.ModelPicker.Error = msg.Err.Error()
			} else {
				m.AddError("Error: " + msg.Err.Error())
			}
			return m, nil
		}
		if m.ActiveSession != nil {
			if msg.Model != "" {
				m.ActiveSession.Model = msg.Model
				m.Chat.Model = msg.Model
			}
			m.ActiveSession.Effort = msg.Effort
			m.Chat.Effort = msg.Effort
			if msg.Provider != "" {
				m.ActiveSession.Provider = msg.Provider
				m.Chat.Provider = msg.Provider
			}
			if msg.Protocol != "" {
				m.ActiveSession.Protocol = msg.Protocol
			}
		}
		m.ModelPicker.Saving = false
		m.State = AppStateChat
		m.ClearNotices()
		return m, nil

	case commandExecutedMsg:
		if msg.Gen != m.CommandGen {
			return m, nil
		}
		m.ClearNotices()
		if msg.Err != nil {
			m.AddError("Error: " + msg.Err.Error())
		} else {
			m.AddNotice(msg.Message)
			if msg.Effort != "" && m.ActiveSession != nil {
				m.ActiveSession.Effort = msg.Effort
				m.Chat.Effort = msg.Effort
			}
		}
		return m, nil

	case glancesPolledMsg:
		if msg.Gen != m.GlanceGen {
			return m, nil
		}
		if msg.Err == nil {
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
			m.AddError("Error: " + msg.Err.Error())
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
			m.SessionGen++
			return m, m.createSessionCmd(m.SessionGen)
		}
		if m.ActiveSession == nil {
			m.State = AppStateSessionPicker
			m.updateSessionPickerItems()
			return m, nil
		}
		m.State = AppStateChat
		return m, nil

	case ChatQuitMsg:
		m.Chat.Close()
		return m, tea.Quit

	case ChatBackToSessionsMsg:
		m.State = AppStateSessionPicker
		m.SessionGen++
		m.GlanceGen++ // Cancels pending glance poll ticks
		return m, tea.Batch(
			m.SessionPicker.Init(),
			m.loadSessionsCmd(m.SessionGen),
		)

	case ChatNewSessionMsg:
		m.SessionGen++
		return m, m.createSessionCmd(m.SessionGen)

	case ChatOpenModelPickerMsg:
		if m.ActiveSession != nil {
			m.ModelPicker = NewModelPickerModel(m.Conn, m.Profiles, m.ActiveSession.Model, m.ActiveSession.Provider)
			m.ModelPicker.SetSize(m.Width, m.Height)
			m.State = AppStateModelPicker
			return m, m.ModelPicker.Init()
		}

	case ModelPickerSelectMsg:
		m.ModelPicker.Saving = true
		m.ModelPicker.Error = ""
		m.ModelGen++
		return m, m.changeModelCmd(msg.Model, msg.Provider, m.ModelGen)

	case ModelPickerCancelMsg:
		m.State = AppStateChat
		return m, nil

	case ChatOpenExtensionPickerMsg:
		if m.ActiveSession != nil {
			m.ExtensionPicker = NewExtensionPickerModel(m.Conn, m.ActiveSession.ID)
			m.ExtensionPicker.SetSize(m.Width, m.Height)
			m.State = AppStateExtensionPicker
			return m, m.ExtensionPicker.Init()
		}

	case ChatOpenWebhooksPageMsg:
		if m.ActiveSession != nil {
			m.WebhooksPage = NewWebhooksPageModel(m.Conn, m.ActiveSession.ID)
			m.WebhooksPage.SetSize(m.Width, m.Height)
			m.State = AppStateWebhooksPage
			return m, m.WebhooksPage.Init()
		}

	case WebhooksPageDoneMsg:
		m.State = AppStateChat
		return m, nil

	case ExtensionPickerDoneMsg:
		m.State = AppStateChat
		return m, nil

	case ExtensionPickerChangedMsg:
		m.ExtensionRevision++
		m.CatalogGen++
		return m, m.loadCommandCatalogCmd(m.CatalogGen)

	case ChatOpenTreePickerMsg:
		if m.ActiveSession != nil {
			m.TreePicker = NewTreePickerModel(m.Conn, m.ActiveSession.ID)
			m.TreePicker.SetSize(m.Width, m.Height)
			m.State = AppStateTreePicker
			return m, m.TreePicker.Init()
		}

	case TreeCancelMsg:
		m.State = AppStateChat
		return m, nil

	case TreeForkSuccessMsg:
		m.Chat.Close()
		branch := msg.Session
		m.ActiveSession = &branch
		m.Sessions = append([]daemon.Session{branch}, m.Sessions...)
		m.Chat = m.newChatModel(&branch)
		m.Chat.SetSize(m.Width, m.Height)
		m.State = AppStateChat
		m.CatalogGen++
		return m, tea.Batch(
			m.Chat.Init(),
			m.loadCommandCatalogCmd(m.CatalogGen),
		)

	case ChatOpenContextInspectorMsg:
		if m.ActiveSession != nil {
			m.ContextInspector = NewContextInspectorModel(m.Conn, m.ActiveSession.ID)
			m.ContextInspector.SetSize(m.Width, m.Height)
			m.State = AppStateContextInspector
			return m, m.ContextInspector.Init()
		}

	case ContextDoneMsg:
		m.State = AppStateChat
		return m, nil

	case ChatOpenCapabilityPageMsg:
		if m.ActiveSession != nil {
			m.CapabilityPage = NewCapabilityPageModel(m.Conn, m.ActiveSession.ID, m.ActiveSession.Workspace, msg.Kind)
			m.CapabilityPage.SetSize(m.Width, m.Height)
			m.State = AppStateCapabilityPage
			return m, m.CapabilityPage.Init()
		}

	case CapabilityPageDoneMsg:
		m.State = AppStateChat
		return m, nil

	case CapabilityPageChangedMsg:
		m.CatalogGen++
		return m, m.loadCommandCatalogCmd(m.CatalogGen)

	case ChatOpenPageMsg:
		if m.ActiveSession != nil {
			m.PageView = NewPageViewModel(m.Conn, m.ActiveSession.ID, msg.Command)
			m.PageView.SetSize(m.Width, m.Height)
			m.State = AppStatePageView
			return m, m.PageView.Init()
		}

	case PageCancelMsg:
		m.State = AppStateChat
		return m, nil

	case PageViewChangedMsg:
		m.GlanceRevision++
		m.GlanceGen++
		var cmds []tea.Cmd
		cmds = append(cmds, m.pollGlancesCmd(m.GlanceGen))
		if m.ActiveSession != nil && m.hasPageCommands() {
			cmds = append(cmds, glancePollTickCmd(m.ActiveSession.ID, m.GlanceGen))
		}
		return m, tea.Batch(cmds...)

	case ChatOpenLoginMsg:
		previous := m.Login.Close()
		m.Login = NewLoginModel(m.Conn, msg.Name)
		m.Login.BrowserOpener = m.BrowserOpener
		m.Login.SetSize(m.Width, m.Height)
		m.State = AppStateLogin
		return m, tea.Batch(previous, m.Login.Init())

	case LoginCancelMsg:
		m.ProfileGen++
		// /login may have removed providers even when it ends without a choice.
		if profiles, err := config.LoadProfiles(config.HomeDir()); err == nil {
			m.Profiles = profiles
		}
		if m.StandaloneLogin {
			return m, tea.Quit
		}
		if m.ActiveSession != nil {
			m.State = AppStateChat
			return m, nil
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
		switch {
		case msg.Name == "/login":
			previous := m.Login.Close()
			m.Login = NewLoginModel(m.Conn, msg.Args)
			m.Login.BrowserOpener = m.BrowserOpener
			m.Login.SetSize(m.Width, m.Height)
			m.State = AppStateLogin
			return m, tea.Batch(previous, m.Login.Init())
		case msg.Name == "/model" && msg.Args != "":
			m.ModelGen++
			return m, m.changeModelCmd(msg.Args, "", m.ModelGen)
		case msg.Name == "/model":
			if m.ActiveSession != nil {
				m.ModelPicker = NewModelPickerModel(m.Conn, m.Profiles, m.ActiveSession.Model, m.ActiveSession.Provider)
				m.ModelPicker.SetSize(m.Width, m.Height)
				m.State = AppStateModelPicker
				return m, m.ModelPicker.Init()
			}
		case msg.Name == "/new":
			m.SessionGen++
			return m, m.createSessionCmd(m.SessionGen)
		case msg.Name == "/sessions" || msg.Name == "/agents" || msg.Name == "/a":
			m.State = AppStateSessionPicker
			m.SessionGen++
			m.GlanceGen++
			return m, tea.Batch(m.SessionPicker.Init(), m.loadSessionsCmd(m.SessionGen))
		case msg.Name == "/extensions" || msg.Name == "/plugins":
			if m.ActiveSession != nil {
				m.ExtensionPicker = NewExtensionPickerModel(m.Conn, m.ActiveSession.ID)
				m.ExtensionPicker.SetSize(m.Width, m.Height)
				m.State = AppStateExtensionPicker
				return m, m.ExtensionPicker.Init()
			}
		case msg.Name == "/tree":
			if m.ActiveSession != nil {
				m.TreePicker = NewTreePickerModel(m.Conn, m.ActiveSession.ID)
				m.TreePicker.SetSize(m.Width, m.Height)
				m.State = AppStateTreePicker
				return m, m.TreePicker.Init()
			}
		case msg.Name == "/context":
			if m.ActiveSession != nil {
				m.ContextInspector = NewContextInspectorModel(m.Conn, m.ActiveSession.ID)
				m.ContextInspector.SetSize(m.Width, m.Height)
				m.State = AppStateContextInspector
				return m, m.ContextInspector.Init()
			}
		default:
			m.CommandGen++
			return m, m.executeCommandCmd(msg.Name, msg.Args, m.CommandGen)
		}

	case PickerSelectMsg:
		if m.State == AppStateSessionPicker {
			if msg.ID == "new" {
				m.SessionGen++
				return m, m.createSessionCmd(m.SessionGen)
			}
			if msg.ID == "archive" {
				m.SessionPicker.OpenArchive()
				return m, nil
			}
			if msg.ID == "login" {
				previous := m.Login.Close()
				m.Login = NewLoginModel(m.Conn, "")
				m.Login.BrowserOpener = m.BrowserOpener
				m.Login.SetSize(m.Width, m.Height)
				m.State = AppStateLogin
				return m, tea.Batch(previous, m.Login.Init())
			}
			// The active session may not yet appear in the daemon's recent list.
			listed := m.Sessions
			if m.ActiveSession != nil {
				found := false
				for _, s := range listed {
					if s.ID == m.ActiveSession.ID {
						found = true
						break
					}
				}
				if !found {
					listed = append([]daemon.Session{*m.ActiveSession}, listed...)
				}
			}
			for _, s := range listed {
				if s.ID == msg.ID {
					m.SessionPicker.RecordOpen(s.ID)
					m.Chat.Close()
					session := s
					m.ActiveSession = &session
					m.Chat = m.newChatModel(&session)
					m.Chat.SetSize(m.Width, m.Height)
					m.ClearNotices()
					m.State = AppStateChat
					m.CatalogGen++
					m.GlanceGen++
					return m, tea.Batch(
						m.Chat.Init(),
						m.loadCommandCatalogCmd(m.CatalogGen),
					)
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
			m.SessionPicker.prefs.Thinking = m.Chat.Flags.Thinking
			m.SessionPicker.prefs.Tools = m.Chat.Flags.Tools
			m.SessionPicker.savePrefs()
			if m.SessionPicker.notice != "" {
				m.Chat.AddError(m.SessionPicker.notice)
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
	case AppStateLogin:
		m.Login, cmd = m.Login.Update(msg)
	}

	return m, cmd
}

func (m AppModel) View() string {
	var prefix strings.Builder
	if m.State == AppStateSessionPicker {
		for _, n := range m.Notices {
			if n.Error {
				prefix.WriteString(DefaultStyles.Error.Render(n.Message) + "\n")
			} else {
				prefix.WriteString(DefaultStyles.Faint.Render(n.Message) + "\n")
			}
		}
	}

	var content string
	switch m.State {
	case AppStateChat:
		content = m.Chat.View()
	case AppStateSessionPicker:
		content = m.SessionPicker.View()
	case AppStateModelPicker:
		content = m.ModelPicker.View()
	case AppStateExtensionPicker:
		content = m.ExtensionPicker.View()
	case AppStateTreePicker:
		content = m.TreePicker.View()
	case AppStateContextInspector:
		content = m.ContextInspector.View()
	case AppStatePageView:
		content = m.PageView.View()
	case AppStateCapabilityPage:
		content = m.CapabilityPage.View()
	case AppStateWebhooksPage:
		content = m.WebhooksPage.View()
	case AppStateLogin:
		content = m.Login.View()
	}

	if prefix.Len() > 0 {
		return prefix.String() + content
	}
	return content
}
