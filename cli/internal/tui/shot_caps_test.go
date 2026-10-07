package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"errors"

	tea "charm.land/bubbletea/v2"
)

// The capability pages' screenshot states: each page's list, filter, odd
// rows, confirmations, saves, forms, and load outcomes.
func init() {
	enter := tea.KeyPressMsg{Code: tea.KeyEnter}
	shiftEnter := tea.KeyPressMsg{Code: tea.KeyEnter, Mod: tea.ModShift}
	down := tea.KeyPressMsg{Code: tea.KeyDown}
	chord := func(r rune) tea.Msg { return tea.KeyPressMsg{Code: r, Mod: tea.ModCtrl} }
	typed := func(text string) []tea.Msg {
		var keys []tea.Msg
		for _, r := range text {
			keys = append(keys, tea.KeyPressMsg{Code: r, Text: string(r)})
		}
		return keys
	}
	saveFailed := func(kind string, items []capabilityItem, keys ...tea.Msg) func(int, int) string {
		return func(w, h int) string {
			m := capsModel(kind, w, h, items, true, nil, keys...)
			m, _ = m.Update(capabilitySavedMsg{Gen: m.Generation, Err: errors.New("daemon refused the change")})
			return m.View()
		}
	}
	skills := capsSkills()
	servers := capsServers()
	registerShots("caps",
		shotState{"skills-list", capsShot("skills", skills, true, capsDiagnostics)},
		shotState{"skills-cursor-overridden", capsShot("skills", skills, true, nil, down)},
		shotState{"skills-cursor-shadowed", capsShot("skills", skills, true, nil, down, down, down)},
		shotState{"skills-cursor-invalid", capsShot("skills", skills, true, nil, down, down, down, down)},
		shotState{"skills-filtering", capsShot("skills", skills, true, nil, typed("notes")...)},
		shotState{"skills-no-match", capsShot("skills", skills, true, nil, typed("zzz")...)},
		shotState{"skills-confirm-global", capsShot("skills", skills, true, nil, enter)},
		shotState{"skills-confirm-session", capsShot("skills", skills, true, nil, shiftEnter)},
		shotState{"skills-confirm-follow-global", capsShot("skills", skills, true, nil, down, chord('x'))},
		shotState{"skills-saving", capsShot("skills", skills, true, nil, shiftEnter, enter)},
		shotState{"skills-save-failed", saveFailed("skills", skills, shiftEnter, enter)},
		shotState{"skills-extension-off", capsShot("skills", skills, false, nil)},
		shotState{"skills-confirm-extension", capsShot("skills", skills, false, nil, chord('t'))},
		shotState{"skills-notice", func(w, h int) string {
			m := capsModel("skills", w, h, skills, true, nil)
			m.Notice = "Saved. Reload the session to apply the selection."
			return m.View()
		}},
		shotState{"skills-loading", func(w, h int) string {
			m := NewCapabilityPageModel(nil, "s", "skills")
			m.SetSize(w, h)
			return m.View()
		}},
		shotState{"skills-empty", capsShot("skills", nil, true, nil)},
		shotState{"skills-load-failed", func(w, h int) string {
			m := NewCapabilityPageModel(nil, "s", "skills")
			m.SetSize(w, h)
			m, _ = m.Update(capabilityLoadedMsg{Gen: m.Generation, Err: errors.New("daemon connection unavailable")})
			return m.View()
		}},
		shotState{"instructions-list", capsShot("instructions", capsInstructions(), true, nil)},
		shotState{"mcp-list", capsShot("mcp", servers, true, nil)},
		shotState{"mcp-cursor-disabled", capsShot("mcp", servers, true, nil, down)},
		shotState{"mcp-filtering", capsShot("mcp", servers, true, nil, typed("fil")...)},
		shotState{"mcp-no-match", capsShot("mcp", servers, true, nil, typed("zzz")...)},
		shotState{"mcp-confirm-global", capsShot("mcp", servers, true, nil, enter)},
		shotState{"mcp-confirm-session", capsShot("mcp", servers, true, nil, shiftEnter)},
		shotState{"mcp-enable-server", capsShot("mcp", servers, true, nil, down, chord('g'))},
		shotState{"mcp-form-add", capsShot("mcp", servers, true, nil, chord('o'))},
		shotState{"mcp-form-add-typed", capsShot("mcp", servers, true, nil, chord('o'), tea.KeyPressMsg{Code: tea.KeyExtended, Text: "http://127.0.0.1:9/mcp"})},
		shotState{"mcp-form-invalid", capsShot("mcp", servers, true, nil, chord('o'), chord('s'))},
		shotState{"mcp-form-edit", capsShot("mcp", servers, true, nil, chord('e'))},
		shotState{"mcp-form-saving", func(w, h int) string {
			m := capsModel("mcp", w, h, servers, true, nil, chord('o'), tea.KeyPressMsg{Code: tea.KeyExtended, Text: "http://127.0.0.1:9/mcp"}, chord('s'))
			return m.View()
		}},
		shotState{"mcp-form-save-failed", saveFailed("mcp", servers, chord('o'), tea.KeyPressMsg{Code: tea.KeyExtended, Text: "http://127.0.0.1:9/mcp"}, chord('s'))},
		shotState{"mcp-confirm-delete", capsShot("mcp", servers, true, nil, chord('d'))},
		shotState{"mcp-delete-save-failed", saveFailed("mcp", servers, chord('d'), enter)},
		shotState{"mcp-confirm-extension", capsShot("mcp", servers, false, nil, chord('t'))},
		shotState{"mcp-extension-off", capsShot("mcp", servers, false, nil)},
		shotState{"mcp-empty", capsShot("mcp", nil, true, nil)},
	)
}

// capsModel is a loaded page of one kind with keys pressed on it.
func capsModel(kind string, width, height int, items []capabilityItem, extension bool, diagnostics []string, keys ...tea.Msg) CapabilityPageModel {
	m := NewCapabilityPageModel(nil, "s", kind)
	m.SetSize(width, height)
	m, _ = m.Update(capabilityLoadedMsg{Gen: m.Generation, ExtensionEnabled: extension, Revision: "rev", Diagnostics: diagnostics, Items: items})
	for _, key := range keys {
		m, _ = m.Update(key)
	}
	return m
}

func capsShot(kind string, items []capabilityItem, extension bool, diagnostics []string, keys ...tea.Msg) func(int, int) string {
	return func(width, height int) string {
		return capsModel(kind, width, height, items, extension, diagnostics, keys...).View()
	}
}

var capsDiagnostics = []string{"skipped one unreadable directory: ~/.agents/skills/old"}

func capsSkills() []capabilityItem {
	key := "draft"
	on, off := true, false
	return []capabilityItem{
		{ID: "enable-review", Title: "enable-review", Candidate: daemon.CatalogCandidate{ID: "enable-review", Source: "/work/.agents/skills/enable-review/SKILL.md", Description: new("verify enabling the skills extension"), PreferenceKey: &key, Valid: true, EffectiveEnabled: true, Eligible: true, GlobalPreference: &on}},
		{ID: "lint-rules", Title: "lint-rules", Candidate: daemon.CatalogCandidate{ID: "lint-rules", Source: "/home/dawn/.agents/skills/lint-rules/SKILL.md", Description: new("house lint rules for go, kept quiet on generated code"), PreferenceKey: &key, Valid: true, GlobalPreference: &on, SessionOverride: &off, Eligible: false}},
		{ID: "release-notes", Title: "release-notes", Candidate: daemon.CatalogCandidate{ID: "release-notes", Source: "/home/dawn/.agents/skills/release-notes/SKILL.md", Description: new("draft changelog entries from commits"), PreferenceKey: &key, Valid: true, GlobalPreference: &off, SessionOverride: &on, EffectiveEnabled: true, Eligible: true}},
		{ID: "tangled", Title: "tangled", Candidate: daemon.CatalogCandidate{ID: "tangled", Source: "/home/dawn/.agents/skills/tangled/SKILL.md", Description: new("tg cli for tangled tasks"), PreferenceKey: &key, Valid: true, ShadowedBy: new("tangled-local"), GlobalPreference: &on}},
		{ID: "broken", Title: "broken", Candidate: daemon.CatalogCandidate{ID: "broken", Source: "/work/.agents/skills/broken/SKILL.md", Description: new("missing frontmatter"), Valid: false, Diagnostic: new("frontmatter has no name")}},
	}
}

func capsInstructions() []capabilityItem {
	key := "agents"
	on := true
	return []capabilityItem{
		{ID: "AGENTS.md", Title: "AGENTS.md", Candidate: daemon.CatalogCandidate{ID: "AGENTS.md", Source: "/work/AGENTS.md", Description: new("workspace conventions"), PreferenceKey: &key, Valid: true, GlobalPreference: &on, EffectiveEnabled: true, Eligible: true}},
		{ID: "CLAUDE.md", Title: "CLAUDE.md", Candidate: daemon.CatalogCandidate{ID: "CLAUDE.md", Source: "/home/dawn/.claude/CLAUDE.md", Description: new("personal notes, shadowed by AGENTS.md"), PreferenceKey: &key, Valid: true, ShadowedBy: new("AGENTS.md")}},
	}
}

func capsServers() []capabilityItem {
	on, off := true, false
	return []capabilityItem{
		{ID: "docs", Title: "docs", Detail: "http · https://docs.example/mcp", Server: config.MCPServer{Type: "http", URL: "https://docs.example/mcp", Enabled: &on, StartupTimeoutMs: 8000}, Secrets: daemon.MCPSecretNames{BearerToken: true, Headers: []string{"X-Team"}}},
		{ID: "filesystem", Title: "filesystem", Detail: "stdio · npx", Server: config.MCPServer{Type: "stdio", Command: "npx", Args: []string{"-y", "@modelcontextprotocol/server-filesystem", "/tmp/notes"}, Enabled: &off, EnabledTools: []string{"read_file"}}},
		{ID: "local", Title: "local", Detail: "http · http://127.0.0.1:8787/mcp", Server: config.MCPServer{Type: "http", URL: "http://127.0.0.1:8787/mcp"}},
	}
}
