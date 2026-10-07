// Acknowledgements race old listings and previews. A daemon E2E cannot control
// their delivery order or inspect search, focus and preview caches in the TUI.
package tui

import (
	"encoding/json"
	"net/http"
	"testing"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/testwire"
	tea "charm.land/bubbletea/v2"
)

func TestPartialPreferencesKeepSharedFactsAndPickerInteraction(t *testing.T) {
	conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, nil)
	active := daemon.Session{ID: "active", Title: "Current", ETag: "active-a", Model: "model"}
	m := NewAppModel(conn, Bootstrap{}, &active, "", false, nil)
	t.Cleanup(m.Chat.Close)
	m.applySessionList([]daemon.Session{active, {ID: "other", Title: "Other", Pinned: true, Opens: 3, ETag: "other-a"}})
	m.ApplyUI(daemon.UIPreferences{ETag: "ui-a", Thinking: true, DismissedNotices: []string{"migration"}})
	m.SessionPicker.SearchInput.SetValue("Other")
	m.SessionPicker.applyFilter()
	m.SessionPicker.focus("other")
	cache := &cachedPreview{SessionPreview: daemon.SessionPreview{Items: []daemon.PreviewItem{{Preview: "kept"}}}}
	m.SessionPicker.previews["other"] = cache
	oldGeneration := m.SessionGen

	m.ApplyUI(daemon.UIPreferences{SessionETags: map[string]string{"active": "active-b"}, Pinned: []string{"active"}})
	m.ApplyUI(daemon.UIPreferences{Opens: map[string]int{"active": 2}})
	m.ApplyUI(daemon.UIPreferences{ETag: "ui-b", Tools: true})
	_, _ = m.Update(sessionsLoadedMsg{Gen: oldGeneration, Sessions: []daemon.Session{active}})
	_, _ = m.Update(SessionPreviewMsg{ID: "active", ExpectedETag: "active-a", Preview: daemon.SessionPreview{Session: &active}})

	if !m.ActiveSession.Pinned || m.ActiveSession.ETag != "active-b" || m.ActiveSession.Opens != 2 || m.ActiveSession.Model != "model" {
		t.Fatalf("lost acknowledged active facts: %+v", m.ActiveSession)
	}
	other, _ := m.session("other")
	if !other.Pinned || other.Opens != 3 || other.ETag != "other-a" {
		t.Fatalf("partial reply replaced another session: %+v", other)
	}
	if m.Chat.Flags.Thinking || !m.Chat.Flags.Tools || len(m.UI.DismissedNotices) != 1 || m.UI.ETag != "ui-b" {
		t.Fatalf("global preference merge lost facts: %+v", m.UI)
	}
	item, ok := m.SessionPicker.Highlighted()
	if !ok || item.ID != "other" || m.SessionPicker.SearchInput.Value() != "Other" || m.SessionPicker.previews["other"] != cache {
		t.Fatal("shared fact update reset picker focus, search or preview cache")
	}
	// Archiving only the active session must preserve another session's pin.
	m.ApplyUI(daemon.UIPreferences{SessionETags: map[string]string{"active": "active-c"}, Archived: []string{"active"}})
	if !m.ActiveSession.Archived || m.ActiveSession.Pinned || !m.Sessions[1].Pinned {
		t.Fatal("archive acknowledgement did not merge per session")
	}
	// Picker snapshots cannot write back into the root owner.
	m.SessionPicker.raw[1].Pinned = false
	if !m.Sessions[1].Pinned {
		t.Fatal("picker snapshot aliases shared session facts")
	}
}

func TestNavigationRefreshRejectsOlderSettingsReply(t *testing.T) {
	settingsReads, sessionLists := 0, 0
	conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/settings":
			settingsReads++
			_ = json.NewEncoder(w).Encode(testwire.Settings())
		case "/sessions":
			sessionLists++
			_ = json.NewEncoder(w).Encode(map[string]any{"items": []any{}, "next": nil})
		default:
			t.Errorf("unexpected refresh request: %s", r.URL)
		}
	})
	m := NewAppModel(conn, Bootstrap{}, nil, "", false, nil)
	m.ApplyUI(daemon.UIPreferences{ETag: "prepared", Tools: true})
	previous := m.SettingsGen
	batch := m.openSessions()().(tea.BatchMsg)
	for _, command := range batch {
		_, _ = m.Update(command())
	}
	_, _ = m.Update(settingsLoadedMsg{Gen: previous, Settings: daemon.Settings{UI: daemon.UIPreferences{ETag: "obsolete", Tools: true}}})
	if sessionLists != 1 || settingsReads != 1 || m.UI.ETag != `"ui-a"` || !m.UI.Thinking || m.UI.Tools {
		t.Fatalf("navigation lost fresh settings or skipped refresh: lists=%d settings=%d ui=%+v", sessionLists, settingsReads, m.UI)
	}
}
