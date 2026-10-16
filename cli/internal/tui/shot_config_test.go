// Gallery states of the /config screen; TestShotGallery/config draws them.
// Without ALBEDO_SHOT_DIR they are only built, which keeps each one buildable.
package tui

import (
	"albedo/cli/internal/daemon"
	"errors"
	"slices"

	tea "charm.land/bubbletea/v2"
)

// gallerySections are the declared settings every config state starts from:
// one extension with a saved value beside its defaults, one the daemon cannot
// read, one whose only setting is text, and the daemon's own limits, one
// saved as unlimited. The unreadable one is web search, so it heads the
// screen.
var gallerySections = []daemon.ExtensionSettingsSection{
	{
		Name:        "rolling",
		Label:       "Rolling summary compaction",
		Category:    daemon.SettingContext,
		Description: "Incremental summary, recent-user recap, and verbatim conversation tail",
		Fields: []daemon.ExtensionSetting{
			{Key: "contextWindowTokens", Label: "Context window", Description: "Tokens this strategy compacts against; unset follows the model's own window.", Kind: daemon.SettingInteger, Minimum: new(int64(1)), Maximum: new(int64(10_000_000))},
			{Key: "triggerPercent", Label: "Trigger", Description: "Percent of the context window at which a compaction runs.", Kind: daemon.SettingInteger, Minimum: new(int64(1)), Maximum: new(int64(99)), Default: daemon.SettingValue{Number: new(int64(80))}, Saved: daemon.SettingValue{Number: new(int64(70))}},
			{Key: "tailPercent", Label: "Tail", Description: "Percent of the window kept verbatim as the newest tail.", Kind: daemon.SettingInteger, Minimum: new(int64(0)), Maximum: new(int64(99)), Default: daemon.SettingValue{Number: new(int64(25))}},
		},
	},
	{
		Name:        "exa",
		Label:       "Exa web search",
		Category:    daemon.SettingWebSearch,
		Description: "Search and page fetching through exa",
		Problem:     "exa triggerPercent must be a whole number from 1 to 99",
		Fields: []daemon.ExtensionSetting{
			{Key: "endpoint", Label: "Endpoint", Description: "Base URL of the exa API.", Kind: daemon.SettingText, Default: daemon.SettingValue{Text: new("https://api.exa.ai")}},
		},
	},
	{
		Name:        "subagents",
		Label:       "Subagents",
		Category:    daemon.SettingAgents,
		Description: "How many agents a session may keep open, and how deep they may nest.",
		Fields: []daemon.ExtensionSetting{
			{Key: "maxOpenChildren", Label: "Open children", Description: "Children one session may have open at once; closing one frees its place. -1 takes the cap away.", Kind: daemon.SettingLimit, Minimum: new(int64(1)), Maximum: new(int64(1000)), Default: daemon.SettingValue{Number: new(int64(12))}, Saved: daemon.SettingValue{Number: new(int64(daemon.SettingNoLimit))}},
			{Key: "maxDepth", Label: "Nesting depth", Description: "Generations of agents below a root session; its children are depth 1.", Kind: daemon.SettingLimit, Minimum: new(int64(1)), Maximum: new(int64(1000)), Default: daemon.SettingValue{Number: new(int64(3))}},
		},
	},
}

func init() {
	enter := tea.KeyPressMsg{Code: tea.KeyEnter}
	down := tea.KeyPressMsg{Code: tea.KeyDown}
	typed := func(text string) []tea.Msg {
		var keys []tea.Msg
		for _, r := range text {
			keys = append(keys, tea.KeyPressMsg{Code: r, Text: string(r)})
		}
		return keys
	}
	registerShots("config",
		shotState{"list", configShot(nil, down)},
		shotState{"list-saved", configShot(nil, down, down)},
		shotState{"list-problem", configShot(nil)},
		shotState{"section-without-fields", func(width, height int) string {
			m := NewConfigPageModel(nil)
			m.SetSize(width, height)
			sections := slices.Concat(gallerySections, []daemon.ExtensionSettingsSection{{Name: "notes", Label: "Compaction notes", Category: daemon.SettingContext, Description: "Scratch notes the model keeps", Problem: "notes must be an object"}})
			m, _ = m.Update(configLoadedMsg{Gen: m.Generation, Settings: daemon.ExtensionSettings{Sections: sections, ETag: `"settings-a"`}})
			return m.View()
		}},
		shotState{"filtering", configShot(nil, typed("trigger")...)},
		shotState{"filter-extension", configShot(nil, typed("exa")...)},
		shotState{"no-match", configShot(nil, typed("zzz")...)},
		shotState{"saving", configShot(func(m *ConfigPageModel) { m.Saving = true })},
		shotState{"notice", configShot(func(m *ConfigPageModel) {
			m.Notice = "These settings changed elsewhere. Review them before saving again."
		})},
		shotState{"loading", func(width, height int) string {
			m := NewConfigPageModel(nil)
			m.SetSize(width, height)
			return m.View()
		}},
		shotState{"empty", func(width, height int) string {
			m := NewConfigPageModel(nil)
			m.SetSize(width, height)
			m, _ = m.Update(configLoadedMsg{Gen: m.Generation, Settings: daemon.ExtensionSettings{ETag: `"settings-a"`}})
			return m.View()
		}},
		shotState{"load-failed", func(width, height int) string {
			m := NewConfigPageModel(nil)
			m.SetSize(width, height)
			m, _ = m.Update(configLoadedMsg{Gen: m.Generation, Err: errors.New("daemon connection unavailable")})
			return m.View()
		}},
		shotState{"form-open", configShot(nil, down, enter)},
		shotState{"form-invalid", configShot(nil, append([]tea.Msg{down, enter}, typed("lots")...)...)},
		shotState{"form-refused", func(width, height int) string {
			m := configModel(width, height, nil)
			m, _ = m.Update(down)
			m, _ = m.Update(enter)
			m.Saving = true
			m, _ = m.Update(configSavedMsg{Gen: m.Generation, Err: &daemon.APIError{StatusCode: 400, Code: "invalid_settings", Message: "rolling percentages must satisfy 0 < tailPercent < triggerPercent < 100"}})
			return m.View()
		}},
	)
}

// configModel is the screen loaded with the gallery's declared settings.
func configModel(width, height int, setup func(*ConfigPageModel)) ConfigPageModel {
	m := NewConfigPageModel(nil)
	m.SetSize(width, height)
	m, _ = m.Update(configLoadedMsg{Gen: m.Generation, Settings: daemon.ExtensionSettings{Sections: gallerySections, ETag: `"settings-a"`}})
	if setup != nil {
		setup(&m)
	}
	return m
}

func configShot(setup func(*ConfigPageModel), keys ...tea.Msg) func(width, height int) string {
	return func(width, height int) string {
		m := configModel(width, height, setup)
		for _, key := range keys {
			m, _ = m.Update(key)
		}
		return m.View()
	}
}
