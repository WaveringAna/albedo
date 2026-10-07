// Gallery states of the Webhooks screen; TestShotGallery/webhooks draws them.
// Without ALBEDO_SHOT_DIR they are only built, which keeps each one buildable.
package tui

import (
	"errors"

	tea "charm.land/bubbletea/v2"
)

// galleryHooks are the fixtures every webhooks state starts from: one queued
// hook, one quiet hook under the same session, and one off hook under another.
var galleryHooks = []webhookEntry{
	{ID: "wh1", Session: "s", Name: "deploy", Enabled: true, URL: "https://albedo.example/extensions/webhooks/hooks/wh1/deliveries", Header: "x-hub-signature-256", Prefix: "sha256=", Queued: 2, Deferred: "session busy"},
	{ID: "wh3", Session: "s", Name: "alerts", Enabled: true, URL: "/extensions/webhooks/hooks/wh3/deliveries", Header: "x-albedo-signature", Prefix: "sha256="},
	{ID: "wh2", Session: "t", Name: "grafana", URL: "/extensions/webhooks/hooks/wh2/deliveries", Header: "x-albedo-signature", Prefix: "sha256="},
}

func init() {
	enter := tea.KeyPressMsg{Code: tea.KeyEnter}
	down := tea.KeyPressMsg{Code: tea.KeyDown}
	shiftTab := tea.KeyPressMsg{Code: tea.KeyTab, Mod: tea.ModShift}
	ctrl := func(r rune) tea.Msg { return tea.KeyPressMsg{Code: r, Mod: tea.ModCtrl} }
	typed := func(text string) []tea.Msg {
		var keys []tea.Msg
		for _, r := range text {
			keys = append(keys, tea.KeyPressMsg{Code: r, Text: string(r)})
		}
		return keys
	}
	registerShots("webhooks",
		shotState{"list", webhooksShot(nil)},
		shotState{"list-agent-on", webhooksShot(func(m *WebhooksPageModel) { m.AgentManagement = true })},
		shotState{"cursor-off", webhooksShot(nil, down, down)},
		shotState{"filtering", webhooksShot(nil, typed("grafana")...)},
		shotState{"filter-session", webhooksShot(nil, typed("release")...)},
		shotState{"no-match", webhooksShot(nil, typed("zzz")...)},
		shotState{"confirm-delete", webhooksShot(nil, ctrl('d'))},
		shotState{"confirm-new-secret", webhooksShot(nil, ctrl('g'))},
		shotState{"saving", webhooksShot(nil, enter)},
		shotState{"save-failed", func(w, h int) string {
			m := webhooksModel(w, h, nil)
			m, _ = m.Update(enter)
			m, _ = m.Update(webhooksSavedMsg{Gen: m.Generation, Err: errors.New("daemon refused the change: webhook etag is stale")})
			return m.View()
		}},
		shotState{"notice", webhooksShot(func(m *WebhooksPageModel) {
			m.Notice = "deploy disabled. New deliveries will receive a 404 response."
		})},
		shotState{"copied-url", webhooksShot(nil, ctrl('l'))},
		shotState{"not-listening", webhooksShot(func(m *WebhooksPageModel) { m.Mounted = false })},
		shotState{"loading", func(w, h int) string {
			m := NewWebhooksPageModel(nil, "s")
			m.SetSize(w, h)
			return m.View()
		}},
		shotState{"empty", func(w, h int) string {
			m := NewWebhooksPageModel(nil, "s")
			m.SetSize(w, h)
			m, _ = m.Update(webhooksLoadedMsg{Gen: m.Generation, Mounted: true, Sessions: webhookSessions})
			return m.View()
		}},
		shotState{"load-failed", func(w, h int) string {
			m := NewWebhooksPageModel(nil, "s")
			m.SetSize(w, h)
			m, _ = m.Update(webhooksLoadedMsg{Gen: m.Generation, Err: errors.New("daemon connection unavailable")})
			return m.View()
		}},
		shotState{"form-add", webhooksShot(nil, ctrl('o'))},
		shotState{"form-add-session", webhooksShot(nil, ctrl('o'), shiftTab)},
		shotState{"form-typed", webhooksShot(nil, append([]tea.Msg{ctrl('o')}, typed("ci-deploys")...)...)},
		shotState{"form-invalid", webhooksShot(nil, ctrl('o'), ctrl('s'))},
		shotState{"form-edit", webhooksShot(nil, ctrl('e'))},
		shotState{"reveal", func(w, h int) string {
			m := webhooksModel(w, h, nil)
			m.Reveal = &webhookSecret{Hook: "deploy", Session: "s", Secret: "whsec_9fQ2xLr7Tq1mZ0vBcW4yHs8dNe3KpA6u"}
			return m.View()
		}},
		shotState{"reveal-copied", func(w, h int) string {
			m := webhooksModel(w, h, nil)
			m.Reveal = &webhookSecret{Hook: "deploy", Session: "s", Secret: "whsec_9fQ2xLr7Tq1mZ0vBcW4yHs8dNe3KpA6u"}
			m, _ = m.Update(ctrl('l'))
			return m.View()
		}},
	)
}

// webhooksModel is the screen loaded with the gallery's hooks.
func webhooksModel(width, height int, setup func(*WebhooksPageModel)) WebhooksPageModel {
	m := NewWebhooksPageModel(nil, "s")
	m.SetSize(width, height)
	m, _ = m.Update(webhooksLoadedMsg{Gen: m.Generation, Mounted: true, Sessions: webhookSessions, Hooks: galleryHooks})
	if setup != nil {
		setup(&m)
	}
	return m
}

func webhooksShot(setup func(*WebhooksPageModel), keys ...tea.Msg) func(width, height int) string {
	return func(width, height int) string {
		m := webhooksModel(width, height, setup)
		for _, key := range keys {
			m, _ = m.Update(key)
		}
		return m.View()
	}
}
