package tui

import (
	"errors"

	tea "charm.land/bubbletea/v2"
)

func init() {
	enter := tea.KeyPressMsg{Code: tea.KeyEnter}
	shiftEnter := tea.KeyPressMsg{Code: tea.KeyEnter, Mod: tea.ModShift}
	down := tea.KeyPressMsg{Code: tea.KeyDown}
	typed := func(text string) []tea.Msg {
		var keys []tea.Msg
		for _, r := range text {
			keys = append(keys, tea.KeyPressMsg{Code: r, Text: string(r)})
		}
		return keys
	}
	registerShots("extensions",
		shotState{"list", extensionsShot(nil)},
		shotState{"filtering", extensionsShot(nil, typed("bs")...)},
		shotState{"no-match", extensionsShot(nil, typed("zzz")...)},
		shotState{"quarantined", extensionsShot(nil, down, down, down)},
		shotState{"confirm-global", extensionsShot(nil, enter)},
		shotState{"confirm-session", extensionsShot(nil, shiftEnter)},
		shotState{"confirm-follow-global", extensionsShot(nil, tea.KeyPressMsg{Code: 'x', Mod: tea.ModCtrl})},
		shotState{"saving", extensionsShot(nil, shiftEnter, enter)},
		shotState{"save-failed", func(w, h int) string {
			m := extensionsModel(w, h, nil)
			m, _ = m.Update(shiftEnter)
			m, _ = m.Update(enter)
			m, _ = m.Update(extensionToggledMsg{Gen: m.Generation, Err: errors.New("daemon refused the change")})
			return m.View()
		}},
		shotState{"notice", extensionsShot(func(m *ExtensionPickerModel) {
			m.Notice = "Saved the global default. Reload sessions to apply it."
		})},
		shotState{"loading", func(w, h int) string {
			m := NewExtensionPickerModel(nil, "s")
			m.SetSize(w, h)
			return m.View()
		}},
		shotState{"empty", func(w, h int) string {
			m := NewExtensionPickerModel(nil, "s")
			m.SetSize(w, h)
			m, _ = m.Update(extensionsLoadedMsg{Gen: m.Generation})
			return m.View()
		}},
		shotState{"load-failed", func(w, h int) string {
			m := NewExtensionPickerModel(nil, "s")
			m.SetSize(w, h)
			m, _ = m.Update(extensionsLoadedMsg{Gen: m.Generation, Err: errors.New("daemon connection unavailable")})
			return m.View()
		}},
	)
}

func extensionsModel(width, height int, setup func(*ExtensionPickerModel)) ExtensionPickerModel {
	m := NewExtensionPickerModel(nil, "s")
	m.SetSize(width, height)
	m, _ = m.Update(extensionsLoadedMsg{Gen: m.Generation, Extensions: []ExtensionItem{
		{Name: "view", Description: "show the model its changes as highlighted images", Enabled: true, Overridden: true, Plugins: []string{"tool"}, Tools: []string{"view_diff"}},
		{Name: "bash", Description: "run shell commands", Enabled: true, GlobalEnabled: true, Plugins: []string{"tool", "context"}, Context: true},
		{Name: "webhooks", Description: "signed inbound requests wake a session"},
		{Name: "mcp", Description: "tool servers", GlobalEnabled: true, Quarantined: "failed to start"},
	}})
	if setup != nil {
		setup(&m)
	}
	return m
}

func extensionsShot(setup func(*ExtensionPickerModel), keys ...tea.Msg) func(width, height int) string {
	return func(width, height int) string {
		m := extensionsModel(width, height, setup)
		for _, key := range keys {
			m, _ = m.Update(key)
		}
		return m.View()
	}
}
