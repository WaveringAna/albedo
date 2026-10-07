// The session list in every state a person sees, for the shot gallery. A
// plain test run draws each state and writes nothing.
package tui

import (
	"time"

	"albedo/cli/internal/daemon"

	tea "charm.land/bubbletea/v2"
)

func init() {
	enter := tea.KeyPressMsg{Code: tea.KeyEnter}
	ctrl := func(r rune) tea.Msg { return tea.KeyPressMsg{Code: r, Mod: tea.ModCtrl} }
	registerShots("sessions",
		shotState{"list", sessionsShot(nil)},
		shotState{"filtering", sessionsShot(nil, typedKeys("warm")...)},
		shotState{"no-match", sessionsShot(nil, typedKeys("zzz")...)},
		shotState{"action-row", sessionsShot(func(m *SessionViewer) { m.focus("new") })},
		shotState{"preview-loading", sessionsShot(func(m *SessionViewer) { m.focus("week") })},
		shotState{"renaming", sessionsShot(nil, ctrl('r'))},
		shotState{"archive", sessionsShot(func(m *SessionViewer) { m.OpenArchive() })},
		shotState{"archive-confirm", sessionsShot(func(m *SessionViewer) { m.OpenArchive() }, ctrl('d'))},
		shotState{"archive-empty", sessionsShot(func(m *SessionViewer) {
			m.SetSessions([]daemon.Session{{ID: "pin", Title: "Only live session"}}, nil)
			m.OpenArchive()
		})},
		shotState{"notice", sessionsShot(func(m *SessionViewer) {
			m.notice = "could not rename: the daemon refused the name"
		})},
		shotState{"loading", func(width, height int) string {
			m := NewSessionViewer("/Users/dawn/proj/albedo")
			m.SetSize(width, height)
			return m.View()
		}},
		shotState{"empty", func(width, height int) string {
			m := sessionsModel(width, height, nil)
			m.SetSessions(nil, nil)
			return m.View()
		}},
		shotState{"confirm-enter", sessionsShot(func(m *SessionViewer) { m.OpenArchive() }, ctrl('d'), enter)},
	)
}

// typedKeys is the keystrokes that type text into a picker.
func typedKeys(text string) []tea.Msg {
	var keys []tea.Msg
	for _, r := range text {
		keys = append(keys, tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	return keys
}

// sessionsModel is the list at a terminal size, with the fixtures every
// state shares, and setup applied before any keys.
func sessionsModel(width, height int, setup func(*SessionViewer)) SessionViewer {
	now := time.Date(2026, 9, 23, 12, 0, 0, 0, time.Local)
	recent, older := now.Add(-5*time.Minute).Unix(), now.Add(-3*24*time.Hour).Unix()
	m := viewerAt(now)
	m.SetSize(width, height)
	m.Fetch = func(string) tea.Cmd { return nil }
	m.SetSessions([]daemon.Session{
		{ID: "pin", Title: "Refactor the session viewer", Model: "claude-sonnet-4", Workspace: "/Users/dawn/proj/albedo", LastAssistantAt: &recent, Pinned: true, Cursor: &daemon.Cursor{}, TranscriptCount: 42},
		{ID: "live", Title: "Fix flaky warm test", Model: "gpt-5", Workspace: "/Users/dawn/proj/albedo", LastAssistantAt: &recent, Cursor: &daemon.Cursor{}, TranscriptCount: 9},
		{ID: "week", Title: "Read the folder picker spec", Model: "claude-opus-4", Workspace: "/Users/dawn/proj/other", LastAssistantAt: &older, TranscriptCount: 3},
		{ID: "old", Title: "Design notes for the archive", Model: "gpt-5", Workspace: "/Users/dawn/proj/albedo", Archived: true},
	}, nil)
	m.focus("live")
	m.previews["live"] = &cachedPreview{stamp: recent, SessionPreview: daemon.SessionPreview{Items: []daemon.PreviewItem{
		{Type: "user", Preview: "why does the warm test flake under load"},
		{Type: "tool", Preview: "read"}, {Type: "tool", Preview: "read"}, {Type: "tool", Preview: "bash"},
		{Type: "assistant", Preview: "the cache ttl was racing the stamp"},
	}}}
	if setup != nil {
		setup(&m)
	}
	return m
}

// sessionsShot draws the list after setup and keys.
func sessionsShot(setup func(*SessionViewer), keys ...tea.Msg) func(width, height int) string {
	return func(width, height int) string {
		m := sessionsModel(width, height, setup)
		for _, key := range keys {
			m, _ = m.Update(key)
		}
		return m.View()
	}
}
