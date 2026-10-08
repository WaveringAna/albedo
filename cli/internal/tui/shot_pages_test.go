package tui

import (
	"albedo/cli/internal/daemon"
	"errors"

	tea "charm.land/bubbletea/v2"
)

// pagesDoc is a page with rows in two badges, one with detail, and actions
// that cover a text, a secret, a choice and a confirmed chord.
func pagesDoc() *PageDocument {
	text := []daemon.FormField{{Name: "text", Label: "text", Type: "text", Required: true}}
	return &PageDocument{
		Title:   "work",
		Summary: "2 open · 2 resolved",
		Empty:   "no work items yet",
		Rows: []PageRow{
			{ID: "12", Text: "fix the webhook retry", Badge: "open", Tone: ToneWarning},
			{ID: "13", Text: "ship the picker", Badge: "open", Tone: ToneActive},
			{ID: "7", Text: "stale binary", Badge: "resolved", Tone: ToneMuted},
			{ID: "3", Text: "ruff not on PATH", Badge: "resolved", Tone: ToneMuted,
				Detail: "ruff is missing from PATH; the binary lives in pre-commit's env.\n\nsuggestion: document the canonical invocation"},
		},
		Actions: []PageAction{
			{ID: "add", Key: "ctrl+o", Label: "add", Fields: text},
			{ID: "edit", Key: "ctrl+e", Label: "edit", Row: true, Fields: text},
			{ID: "delete", Key: "ctrl+d", Label: "delete", Row: true, Confirm: true, Confirmation: "Delete this item?"},
			{ID: "toggle", Key: "ctrl+t", Label: "done", Row: true, Fields: []daemon.FormField{{Name: "done", Label: "done", Type: "boolean"}}},
			{ID: "secret", Key: "ctrl+g", Label: "new secret", Row: true, Fields: []daemon.FormField{{Name: "secret", Label: "replacement", Type: "secret", Required: true}}},
		},
	}
}

func pagesModel(width, height int, doc *PageDocument) PageViewModel {
	m := NewPageViewModel(nil, "s", "/work")
	m.SetSize(width, height)
	m.setDoc(doc)
	m.Busy = false
	return m
}

// pagesChord is a ctrl chord press, the way actions are reached.
func pagesChord(letter rune) tea.KeyPressMsg {
	return tea.KeyPressMsg{Code: letter, Mod: tea.ModCtrl}
}

func pagesShot(keys ...tea.Msg) func(width, height int) string {
	return func(width, height int) string {
		m := pagesModel(width, height, pagesDoc())
		for _, key := range keys {
			m, _ = m.Update(key)
		}
		return m.View()
	}
}

func init() {
	down := tea.KeyPressMsg{Code: tea.KeyDown}
	registerShots("pages",
		shotState{"list", pagesShot()},
		shotState{"filtering", pagesShot(shotTyped("ruff")...)},
		shotState{"no-match", pagesShot(shotTyped("zzz")...)},
		shotState{"row-detail", pagesShot(down, down, down)},
		shotState{"confirm", pagesShot(pagesChord('d'))},
		shotState{"text-prompt", pagesShot(pagesChord('o'))},
		shotState{"secret-prompt", pagesShot(down, down, down, pagesChord('g'), tea.KeyPressMsg{Code: 's', Text: "s"})},
		shotState{"choice-prompt", pagesShot(down, pagesChord('t'))},
		shotState{"actions-menu", pagesShot(pagesChord('a'))},
		shotState{"busy", func(width, height int) string {
			m := pagesModel(width, height, pagesDoc())
			m.Busy = true
			return m.View()
		}},
		shotState{"notice", func(width, height int) string {
			m := pagesModel(width, height, pagesDoc())
			m.Notice = "added: write the release notes"
			return m.View()
		}},
		shotState{"error", func(width, height int) string {
			m := pagesModel(width, height, pagesDoc())
			m.Error = "daemon refused the change"
			return m.View()
		}},
		shotState{"empty", func(width, height int) string {
			doc := pagesDoc()
			doc.Rows = nil
			return pagesModel(width, height, doc).View()
		}},
		shotState{"loading", func(width, height int) string {
			m := NewPageViewModel(nil, "s", "/work")
			m.SetSize(width, height)
			return m.View()
		}},
		shotState{"load-failed", func(width, height int) string {
			m := NewPageViewModel(nil, "s", "/work")
			m.SetSize(width, height)
			m, _ = m.Update(pageLoadedMsg{Gen: m.Generation, Err: errors.New("daemon connection unavailable")})
			return m.View()
		}},
	)
}
