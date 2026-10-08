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

	tea "charm.land/bubbletea/v2"
)

func (m *AppModel) handleCommandResults(msg tea.Msg) (tea.Cmd, bool) {
	switch msg := msg.(type) {
	case modelChangedMsg:
		if msg.Gen != m.ModelGen || m.ActiveSession == nil || msg.SessionID != m.ActiveSession.ID {
			return nil, true
		}
		if msg.Selection != nil {
			selected := msg.Selection
			m.ActiveSession.Model, m.Chat.Model = selected.Model, selected.Model
			m.ActiveSession.Effort, m.Chat.Effort = selected.Effort, selected.Effort
			m.ActiveSession.Provider, m.Chat.Provider = selected.Provider, selected.Provider
			m.ActiveSession.Protocol = selected.Protocol
			m.ActiveSession.ETag = selected.ETag
			m.updateSession(*m.ActiveSession)
			if selected.DefaultETag != "" {
				m.Profiles.ETag = selected.DefaultETag
				m.Profiles.Active = selected.Provider
				profile := m.Profiles.Providers[selected.Provider]
				profile.Model = selected.Model
				profile.Effort = nil
				if selected.Effort != "" {
					profile.Effort = new(selected.Effort)
				}
				if m.Profiles.Providers != nil {
					m.Profiles.Providers[selected.Provider] = profile
				}
			}
			if selected.ModelsETag != "" {
				if m.SettingsETags == nil {
					m.SettingsETags = map[string]string{}
				}
				m.SettingsETags["models"] = selected.ModelsETag
			}
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
		return nil, true
	case commandExecutedMsg:
		if msg.Gen != m.CommandGen || (msg.SessionID != "" && (m.ActiveSession == nil || msg.SessionID != m.ActiveSession.ID)) {
			return nil, true
		}
		if msg.ModelsETag != "" {
			if m.SettingsETags == nil {
				m.SettingsETags = map[string]string{}
			}
			m.SettingsETags["models"] = msg.ModelsETag
		}
		m.ClearNotices()
		if len(msg.Available) > 0 && m.State == AppStateChat {
			m.Chat.openEffortSelector(msg.Available)
			return nil, true
		}
		if msg.Err != nil {
			m.AddError(operationError(msg.Err, "Command error: ", msg.Name+" may have run; check its result before running it again."))
			return nil, true
		}
		if msg.Page != nil && m.State == AppStateChat && m.ActiveSession != nil {
			m.PageView = NewPageViewModel(m.Conn, m.ActiveSession.ID, msg.Name)
			m.PageView.setDoc(msg.Page)
			m.PageView.Busy = false
			m.PageView.SetSize(m.Width, m.Height)
			m.State = AppStatePageView
			return nil, true
		}
		m.AddNotice(msg.Message)
		if msg.EffortChanged && m.ActiveSession != nil {
			m.ActiveSession.Effort = msg.Effort
			m.ActiveSession.ETag = msg.ETag
			m.Chat.Effort = msg.Effort
			m.updateSession(*m.ActiveSession)
		}
		return nil, true
	case profilesLoadedMsg:
		if msg.Gen != m.ProfileGen {
			return nil, true
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
			return tea.Quit, true
		}
		if msg.Err == nil && m.ActiveSession == nil && len(m.Sessions) == 0 {
			return m.newSessionCmd(), true
		}
		if m.ActiveSession == nil {
			m.State = AppStateSessionPicker
			m.updateSessionPickerItems()
			return nil, true
		}
		return m.returnToChat(), true
	}
	return nil, false
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

func (m *AppModel) changeModelCmd(model, provider, effort string, raiseCap *bool, gen int, capKey string) tea.Cmd {
	conn, hasSession := m.Conn, m.ActiveSession != nil
	var sessionID, currentProvider, etag string
	if hasSession {
		sessionID, currentProvider, etag = m.ActiveSession.ID, m.ActiveSession.Provider, m.ActiveSession.ETag
	}
	modelsETag := m.SettingsETags["models"]
	providersETag := m.Profiles.ETag
	profiles := maps.Clone(m.Profiles.Providers)
	saveCap := raiseCap != nil
	var capEnabled bool
	if saveCap {
		capEnabled = *raiseCap
	}
	return func() tea.Msg {
		if conn == nil || !hasSession {
			return modelChangedMsg{Err: errors.New("no active session or connection"), SessionID: sessionID, Gen: gen}
		}

		if provider == "" {
			resolved, selected, resolveErr := daemon.ResolveSessionModel(config.Profiles{Active: currentProvider, Providers: profiles}, model)
			if resolveErr != nil {
				return modelChangedMsg{Err: resolveErr, SessionID: sessionID, Gen: gen}
			}
			provider, model = resolved, selected
		}
		selection, err := daemon.ChangeModel(context.Background(), conn, sessionID, daemon.ModelChangeRequest{Model: model, Provider: provider, Effort: effort, CurrentProvider: currentProvider, ETag: etag, DefaultETag: providersETag, MakeDefault: true})
		if selection.Model == "" {
			return modelChangedMsg{Err: err, SessionID: sessionID, Gen: gen}
		}
		if profile, ok := profiles[selection.Provider]; ok {
			selection.Protocol = profile.Protocol
		}
		changed := modelChangedMsg{Selection: &selection, SessionID: sessionID, Gen: gen, Err: err}
		if err != nil {
			return changed
		}
		// Keep the confirmed switch if the following cap update fails.
		if saveCap {
			updatedETag, err := daemon.SetModelContextCap(context.Background(), conn, daemon.ModelContextCapRequest{CapKey: capKey, ETag: modelsETag, Enabled: capEnabled})
			if err != nil {
				changed.Err = fmt.Errorf("switched model; context cap update: %w", err)
				return changed
			}
			selection.ModelsETag = updatedETag
		}

		return changed
	}
}

func (m *AppModel) executeCommandCmd(name, args string, gen int) tea.Cmd {
	var captured daemon.Session
	if m.ActiveSession != nil {
		captured = *m.ActiveSession
	}
	catalog := slices.Clone(m.CommandCatalog)
	conn, hasSession := m.Conn, m.ActiveSession != nil
	modelsETag := m.SettingsETags["models"]
	currentProfile := profilesForSession(m.Profiles, captured)
	var sessionID string
	if hasSession {
		sessionID = m.ActiveSession.ID
	}
	return func() tea.Msg {
		if conn == nil || !hasSession {
			return commandExecutedMsg{Name: name, Err: errors.New("no active session or connection"), Gen: gen}
		}

		snapshot := captured
		var res daemon.CommandResult
		var err error
		var acknowledgedModelsETag string
		switch name {
		case "/effort":
			var effort daemon.EffortResult
			if args == "" {
				effort, err = daemon.ReadEffort(context.Background(), conn, snapshot)
			} else {
				effort, err = daemon.SelectEffort(context.Background(), conn, snapshot, args)
			}
			res.Effort = &effort
		case "/raise-cap":
			enabled := true
			switch strings.TrimSpace(args) {
			case "", "on", "true":
			case "off", "false":
				enabled = false
			default:
				err = errors.New("use /raise-cap [on|off]")
			}
			if err != nil {
				break
			}
			models, readErr := daemon.ListProfileModels(context.Background(), conn, currentProfile)
			if readErr != nil {
				err = readErr
				break
			}
			capKey := ""
			for _, model := range models {
				if model.ID == snapshot.Model {
					capKey = model.CapKey
					break
				}
			}
			acknowledgedModelsETag, err = daemon.SetModelContextCap(context.Background(), conn, daemon.ModelContextCapRequest{CapKey: capKey, ETag: modelsETag, Enabled: enabled})
			res.Message = "Context cap preference saved."
		case "/reload":
			target := strings.TrimSpace(args)
			if target == "" {
				target = "both"
			}
			var reloaded daemon.SessionReloadResult
			reloaded, err = daemon.ReloadSession(context.Background(), conn, sessionID, daemon.ReloadRequest{Target: target})
			res.Message = reloaded.Message()
		case "/kernel":
			var upgraded daemon.KernelUpgradeResult
			upgraded, err = daemon.UpgradeKernel(context.Background(), conn, sessionID)
			res.Message = upgraded.Message()
		case "/compact":
			var compacted daemon.CompactionResult
			compacted, err = daemon.CompactSession(context.Background(), conn, sessionID, strings.TrimSpace(args))
			res.Message = compacted.Message()
		default:
			// A name can carry a read and a change; typed text picks the one
			// that takes arguments.
			index := slices.IndexFunc(catalog, func(item daemon.SessionCommand) bool {
				return item.Name == name && args != "" && len(item.Arguments) > 0
			})
			if index < 0 {
				index = slices.IndexFunc(catalog, func(item daemon.SessionCommand) bool { return item.Name == name })
			}
			if index < 0 {
				err = fmt.Errorf("command %s is not in the loaded catalog", name)
				break
			}
			command := catalog[index]
			arguments, parseErr := daemon.ParseCommandArguments(command, args)
			if parseErr != nil {
				err = parseErr
				break
			}
			res, err = daemon.InvokeDeclaredCommand(context.Background(), conn, snapshot, command, arguments)
		}

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

		return commandExecutedMsg{Name: name, Message: msg, Page: res.Page, Effort: newEffort, ModelsETag: acknowledgedModelsETag, ETag: func() string {
			if res.Effort != nil {
				return res.Effort.ETag
			}
			return ""
		}(), EffortChanged: res.Effort != nil, SessionID: sessionID, Gen: gen}
	}
}

func profilesForSession(profiles config.Profiles, session daemon.Session) config.Settings {
	profile := profiles.Providers[session.Provider]
	profile.ProfileName = session.Provider
	return profile
}

func (m *AppModel) handleCommandInvocation(msg tea.Msg) (tea.Cmd, bool) {
	switch msg := msg.(type) {
	case ChatExecuteCommandMsg:
		if slices.ContainsFunc(m.CommandCatalog, func(command daemon.SessionCommand) bool {
			return command.Name == msg.Name && command.Delivery == "input"
		}) {
			var commands []tea.Cmd
			m.Chat.handleSubmittedCommand(strings.TrimSpace(msg.Name+" "+msg.Args), &commands)
			return tea.Batch(commands...), true
		}
		switch msg.Name {
		case "/login":
			return m.openLogin(msg.Args), true
		case "/model":
			if msg.Args != "" {
				m.ModelGen++
				return m.changeModelCmd(msg.Args, "", "", nil, m.ModelGen, ""), true
			}
			return m.openModelPicker(), true
		case "/work", "/paperclips":
			if m.ActiveSession == nil {
				return nil, true
			}
			if strings.TrimSpace(msg.Args) == "" {
				return func() tea.Msg { return ChatOpenPageMsg{Command: msg.Name} }, true
			}
			m.PageView = NewPageViewModel(m.Conn, m.ActiveSession.ID, msg.Name)
			m.PageView.SetSize(m.Width, m.Height)
			m.State = AppStatePageView
			return m.PageView.shortcutCmd(msg.Args), true
		case "/link":
			if m.ActiveSession == nil {
				return nil, true
			}
			action, target, _ := strings.Cut(strings.TrimSpace(msg.Args), " ")
			if action == "add" && strings.TrimSpace(target) != "" {
				snapshot := *m.ActiveSession
				conn := m.Conn
				m.PageView = NewPageViewModel(conn, snapshot.ID, "/links")
				m.PageView.SetSize(m.Width, m.Height)
				m.State = AppStatePageView
				gen := m.PageView.Generation
				return func() tea.Msg {
					doc, err := daemon.PrepareLinkMerge(context.Background(), conn, snapshot, strings.TrimSpace(target))
					return pageLoadedMsg{Doc: doc, Err: err, Gen: gen}
				}, true
			}
			return func() tea.Msg { return ChatOpenPageMsg{Command: "/links"} }, true
		case "/new":
			return m.newSessionCmd(), true
		case "/agents":
			return func() tea.Msg { return ChatOpenAgentsMsg{} }, true
		case "/sessions", "/a":
			return m.openSessions(), true
		case "/extensions", "/plugins":
			return m.openExtensionPicker(), true
		case "/tree":
			return m.openTreePicker(), true
		case "/cd":
			if msg.Args == "" || m.ActiveSession == nil {
				return m.openFolderPicker(nil), true
			}
			return moveCmd(daemonFolders{conn: m.Conn, condition: daemon.SessionCondition{ETag: m.ActiveSession.ETag, FamilyRevision: m.ActiveSession.FamilyRevision}}, m.ActiveSession.ID, m.ActiveSession.Workspace, msg.Args, nil), true
		case "/context":
			return m.openContextInspector(), true
		default:
			m.CommandGen++
			return m.executeCommandCmd(msg.Name, msg.Args, m.CommandGen), true
		}
	}
	return nil, false
}
