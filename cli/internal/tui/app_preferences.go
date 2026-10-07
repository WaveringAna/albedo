package tui

import (
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"slices"

	tea "charm.land/bubbletea/v2"
)

func (m *AppModel) handlePreferences(msg tea.Msg) (tea.Cmd, bool) {
	switch msg := msg.(type) {
	case settingsLoadedMsg:
		if msg.Gen != m.SettingsGen {
			return nil, true
		}
		if msg.Err != nil {
			m.Chat.AddError(msg.Err.Error())
			m.SessionPicker.notice = msg.Err.Error()
			return nil, true
		}
		m.Profiles = msg.Settings.Profiles
		m.SettingsETags = msg.Settings.ETags
		m.ApplyUI(msg.Settings.UI)
		return nil, true
	case uiSavedMsg:
		if msg.Open {
			if msg.Err != nil {
				m.Chat.AddError(msg.Err.Error())
				if _, uncertain := errors.AsType[*daemon.UncertainOutcomeError](msg.Err); uncertain {
					return nil, true
				}
			}
			if msg.Err == nil {
				m.ApplyUI(msg.Prefs)
			}
			return m.refreshSettingsCmd(), true
		}
		// One save runs at a time, so this answer always ends it.
		m.UISaving, m.SessionPicker.Saving = false, false
		if msg.Session == "" && msg.Gen != m.SettingsGen {
			// The settings read an invalidation asked for waited on this save.
			return m.loadSettingsCmd(m.SettingsGen), true
		}
		if msg.Err != nil {
			m.Chat.AddError(msg.Err.Error())
			m.SessionPicker.notice = msg.Err.Error()
			return nil, true
		}
		m.SessionPicker.notice = ""
		m.ApplyUI(msg.Prefs)
		if msg.Session == "" {
			return nil, true
		}
		if !m.listingSessions {
			return nil, true
		}
		// The listing in flight predates the save and would undo it.
		m.SessionGen++
		return m.loadSessionsCmd(m.SessionGen), true
	case SessionPreferenceMsg:
		if m.UISaving {
			m.SessionPicker.Saving = false
			return nil, true
		}
		m.UISaving = true
		m.SettingsGen++
		m.SessionGen++
		patch := daemon.UIPreferencesPatch{ETag: msg.ETag}
		switch msg.Field {
		case "pinned":
			patch.Pinned = &msg.Value
		case "archived":
			patch.Archived = &msg.Value
		}
		return m.patchUICmd(msg.ID, patch, m.SettingsGen), true
	}
	return nil, false
}

// ApplyUI takes acknowledged shared preferences from the daemon.
func (m *AppModel) ApplyUI(prefs daemon.UIPreferences) {
	if len(prefs.SessionETags) != 0 || len(prefs.Opens) != 0 {
		m.SessionGen++ // Earlier listings predate these acknowledged session facts.
	}
	if prefs.ETag != "" {
		m.UI.Thinking, m.UI.Tools, m.UI.ETag = prefs.Thinking, prefs.Tools, prefs.ETag
		if prefs.DismissedNotices != nil {
			m.UI.DismissedNotices = slices.Clone(prefs.DismissedNotices)
		}
	}
	for i := range m.Sessions {
		m.Sessions[i] = applySessionPreferences(m.Sessions[i], prefs)
	}
	if m.ActiveSession != nil {
		captured := applySessionPreferences(*m.ActiveSession, prefs)
		m.ActiveSession = &captured
	}
	m.updateSessionPickerItems()
	m.Chat.Flags.Thinking, m.Chat.Flags.Tools = m.UI.Thinking, m.UI.Tools
}

func applySessionPreferences(session daemon.Session, prefs daemon.UIPreferences) daemon.Session {
	if etag, updated := prefs.SessionETags[session.ID]; updated {
		session.ETag = etag
		session.Pinned = slices.Contains(prefs.Pinned, session.ID)
		session.Archived = slices.Contains(prefs.Archived, session.ID)
	}
	if opens, updated := prefs.Opens[session.ID]; updated {
		session.Opens = opens
	}
	return session
}

func (m *AppModel) refreshSettingsCmd() tea.Cmd {
	if m.UISaving {
		return nil
	}
	m.SettingsGen++
	return m.loadSettingsCmd(m.SettingsGen)
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
	if session == "" {
		patch.ETag = m.UI.ETag
	}
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
		return uiSavedMsg{Prefs: prefs, Gen: gen, Session: session, Err: err}
	}
}

func (m *AppModel) recordOpenCmd(session string) tea.Cmd {
	conn := m.Conn
	return func() tea.Msg {
		prefs, err := daemon.RecordOpen(context.Background(), conn, session)
		return uiSavedMsg{Prefs: prefs, Open: true, Err: err}
	}
}
