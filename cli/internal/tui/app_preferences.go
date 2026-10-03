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
			return m.loadSettingsCmd(m.SettingsGen), true
		}
		if msg.Gen != m.SettingsGen {
			return nil, true
		}
		m.UISaving, m.SessionPicker.Saving = false, false
		if msg.Err != nil {
			m.Chat.AddError(msg.Err.Error())
			m.SessionPicker.notice = msg.Err.Error()
			return nil, true
		}
		m.SessionPicker.notice = ""
		m.ApplyUI(msg.Prefs)
		return nil, true
	case SessionPreferenceMsg:
		if m.UISaving {
			m.SessionPicker.Saving = false
			return nil, true
		}
		m.UISaving = true
		m.SettingsGen++
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
	current := &m.SessionPicker.prefs
	if prefs.ETag != "" {
		current.Thinking, current.Tools, current.ETag = prefs.Thinking, prefs.Tools, prefs.ETag
	}
	if current.Opens == nil {
		current.Opens = map[string]int{}
	}
	for id, opens := range prefs.Opens {
		current.Opens[id] = opens
	}
	for id, etag := range prefs.SessionETags {
		current.Pinned = slices.DeleteFunc(current.Pinned, func(v string) bool { return v == id })
		current.Archived = slices.DeleteFunc(current.Archived, func(v string) bool { return v == id })
		if slices.Contains(prefs.Pinned, id) {
			current.Pinned = append(current.Pinned, id)
		}
		if slices.Contains(prefs.Archived, id) {
			current.Archived = append(current.Archived, id)
		}
		for i := range m.Sessions {
			if m.Sessions[i].ID == id {
				m.Sessions[i].ETag = etag
				m.Sessions[i].Pinned = slices.Contains(prefs.Pinned, id)
				m.Sessions[i].Archived = slices.Contains(prefs.Archived, id)
			}
		}
		for i := range m.SessionPicker.raw {
			if m.SessionPicker.raw[i].ID == id {
				m.SessionPicker.raw[i].ETag = etag
				m.SessionPicker.raw[i].Pinned = slices.Contains(prefs.Pinned, id)
				m.SessionPicker.raw[i].Archived = slices.Contains(prefs.Archived, id)
			}
		}
		if m.ActiveSession != nil && m.ActiveSession.ID == id {
			m.ActiveSession.ETag = etag
		}
	}
	m.SessionPicker.rebuild()
	m.Chat.Flags.Thinking, m.Chat.Flags.Tools = current.Thinking, current.Tools

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
		patch.ETag = m.SessionPicker.prefs.ETag
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
