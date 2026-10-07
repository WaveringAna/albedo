package tui

import (
	"albedo/cli/internal/daemon"
	"errors"

	tea "charm.land/bubbletea/v2"
)

// shotTyped is the key presses that type text into a filter.
func shotTyped(text string) []tea.Msg {
	var keys []tea.Msg
	for _, r := range text {
		keys = append(keys, tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	return keys
}

func treeModel(width, height int) TreePickerModel {
	m := NewTreePickerModel(nil, "s")
	m.SetSize(width, height)
	m, _ = m.Update(treeLoadedMsg{Gen: m.Generation, Items: []daemon.TreeCheckpoint{
		{ID: "a", Type: "user", Preview: "add a retry to the webhook sender"},
		{ID: "b", Type: "assistant", Preview: "I'll look at the sender first, then the queue it drains into."},
		{ID: "c", Type: "user", Preview: "also the tests"},
		{ID: "d", Type: "assistant", Preview: "done: retry with backoff, three attempts, tests pass"},
		{ID: "e", Type: "user", Preview: "ship it"},
	}})
	return m
}

func treeShot(keys ...tea.Msg) func(width, height int) string {
	return func(width, height int) string {
		m := treeModel(width, height)
		for _, key := range keys {
			m, _ = m.Update(key)
		}
		return m.View()
	}
}

func init() {
	enter := tea.KeyPressMsg{Code: tea.KeyEnter}
	down := tea.KeyPressMsg{Code: tea.KeyDown}
	registerShots("tree",
		shotState{"list", treeShot(down)},
		shotState{"filtering", treeShot(shotTyped("retry")...)},
		shotState{"no-match", treeShot(shotTyped("zzz")...)},
		shotState{"confirm-branch", treeShot(enter)},
		shotState{"branching", treeShot(enter, enter)},
		shotState{"branch-failed", func(width, height int) string {
			m := treeModel(width, height)
			m, _ = m.Update(enter)
			m, _ = m.Update(enter)
			m, _ = m.Update(treeForkedMsg{Gen: m.Generation, Err: errors.New("the daemon refused the branch")})
			return m.View()
		}},
		shotState{"loading", func(width, height int) string {
			m := NewTreePickerModel(nil, "s")
			m.SetSize(width, height)
			return m.View()
		}},
		shotState{"empty", func(width, height int) string {
			m := NewTreePickerModel(nil, "s")
			m.SetSize(width, height)
			m, _ = m.Update(treeLoadedMsg{Gen: m.Generation})
			return m.View()
		}},
		shotState{"load-failed", func(width, height int) string {
			m := NewTreePickerModel(nil, "s")
			m.SetSize(width, height)
			m, _ = m.Update(treeLoadedMsg{Gen: m.Generation, Err: errors.New("daemon connection unavailable")})
			return m.View()
		}},
	)
}
