package tui

import (
	"albedo/cli/internal/daemon"
	"errors"

	tea "charm.land/bubbletea/v2"
)

func contextSnapshot() *daemon.ContextSnapshot {
	window := 200000
	return &daemon.ContextSnapshot{
		State: "ready", Provider: "claude", Model: "claude-sonnet", Protocol: "messages",
		ContextWindowTokens: &window,
		Sections: []daemon.ContextSection{
			{ID: "system", Label: "System instructions", Kind: "system", Source: "AGENTS.md + workspace", ItemCount: 3, ByteCount: 9120, Pages: 1, Preview: "You are albedo, a coding agent..."},
			{ID: "tools", Label: "Tool definitions", Kind: "tools", Source: "extensions", ItemCount: 14, ByteCount: 22040, Pages: 2},
			{ID: "history", Label: "Conversation history", Kind: "history", Source: "transcript", ItemCount: 58, ByteCount: 184320, Pages: 9, Preview: "user: add a retry to the webhook sender"},
			{ID: "input", Label: "Current input", Kind: "input", Source: "this turn", ItemCount: 1, ByteCount: 212},
		},
	}
}

// contextModel is the inspector with a ready snapshot, sized to the shot.
func contextModel(width, height int) ContextInspectorModel {
	m := NewContextInspectorModel(nil, "s")
	m.SetSize(width, height)
	m, _ = m.Update(contextSnapshotLoadedMsg{Gen: m.Generation, Snapshot: contextSnapshot()})
	return m
}

func contextShot(keys ...tea.Msg) func(width, height int) string {
	return func(width, height int) string {
		m := contextModel(width, height)
		for _, key := range keys {
			m, _ = m.Update(key)
		}
		return m.View()
	}
}

// contextReader opens the history section with its first page loaded.
func contextReader(width, height int, page daemon.ContextPage) ContextInspectorModel {
	m := contextModel(width, height)
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	m, _ = m.Update(contextPageLoadedMsg{Gen: m.Generation, SectionID: "history", Data: &page})
	return m
}

func historyPage() daemon.ContextPage {
	content := "user: add a retry to the webhook sender\n"
	for range 40 {
		content += "assistant: looked at internal/hooks/sender.go and the queue it drains into\n"
	}
	return daemon.ContextPage{Content: content, Pages: 9}
}

func init() {
	enter := tea.KeyPressMsg{Code: tea.KeyEnter}
	down := tea.KeyPressMsg{Code: tea.KeyDown}
	registerShots("context",
		shotState{"list", contextShot(down, down)},
		shotState{"no-content", contextShot(down, down, down)},
		shotState{"filtering", contextShot(shotTyped("hist")...)},
		shotState{"no-match", contextShot(shotTyped("zzz")...)},
		shotState{"reader", func(width, height int) string {
			return contextReader(width, height, historyPage()).View()
		}},
		shotState{"reader-scrolled", func(width, height int) string {
			m := contextReader(width, height, historyPage())
			m.View()
			for range 12 {
				m, _ = m.Update(down)
			}
			return m.View()
		}},
		shotState{"reader-loading", func(width, height int) string {
			m := contextModel(width, height)
			m, _ = m.Update(down)
			m, _ = m.Update(down)
			m, _ = m.Update(enter)
			return m.View()
		}},
		shotState{"reader-failed", func(width, height int) string {
			m := contextModel(width, height)
			m, _ = m.Update(down)
			m, _ = m.Update(down)
			m, _ = m.Update(enter)
			m, _ = m.Update(contextPageLoadedMsg{Gen: m.Generation, SectionID: "history", Err: errors.New("page 1 is no longer available")})
			return m.View()
		}},
		shotState{"reader-omitted", func(width, height int) string {
			page := historyPage()
			page.Omitted = "earlier turns were dropped from this request"
			return contextReader(width, height, page).View()
		}},
		shotState{"pending", func(width, height int) string {
			m := NewContextInspectorModel(nil, "s")
			m.SetSize(width, height)
			m, _ = m.Update(contextSnapshotLoadedMsg{Gen: m.Generation, Snapshot: &daemon.ContextSnapshot{State: "pending", Reason: "the session has not sent a request yet"}})
			return m.View()
		}},
		shotState{"empty", func(width, height int) string {
			m := NewContextInspectorModel(nil, "s")
			m.SetSize(width, height)
			m, _ = m.Update(contextSnapshotLoadedMsg{Gen: m.Generation, Snapshot: &daemon.ContextSnapshot{State: "ready", Provider: "claude", Model: "claude-sonnet"}})
			return m.View()
		}},
		shotState{"loading", func(width, height int) string {
			m := NewContextInspectorModel(nil, "s")
			m.SetSize(width, height)
			return m.View()
		}},
		shotState{"load-failed", func(width, height int) string {
			m := NewContextInspectorModel(nil, "s")
			m.SetSize(width, height)
			m, _ = m.Update(contextSnapshotLoadedMsg{Gen: m.Generation, Err: errors.New("daemon connection unavailable")})
			return m.View()
		}},
	)
}
