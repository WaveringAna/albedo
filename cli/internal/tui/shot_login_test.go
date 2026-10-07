// The login steps in every state a person sees, for the shot gallery. A plain
// test run draws each state and writes nothing.
package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"

	tea "charm.land/bubbletea/v2"
)

func init() {
	registerShots("login",
		shotState{"provider-list", loginShot(nil)},
		shotState{"provider-filter", loginShot(nil, typedKeys("cla")...)},
		shotState{"provider-no-match", loginShot(nil, typedKeys("zzz")...)},
		shotState{"provider-remove-ask", loginShot(nil, tea.KeyPressMsg{Code: 'd', Mod: tea.ModCtrl})},
		shotState{"provider-remove-stray-key", loginShot(nil, tea.KeyPressMsg{Code: 'd', Mod: tea.ModCtrl}, tea.KeyPressMsg{Code: 'x', Text: "x"})},
		shotState{"provider-error", loginShot(func(m *LoginModel) { m.Error = "daemon refused the change" })},
		shotState{"first-run", loginEmpty(nil)},
		shotState{"first-run-sign-in-hint", loginEmpty(func(m *LoginModel) { m.Step = StepName })},
		shotState{"load-failed", loginEmpty(func(m *LoginModel) { m.Error = "daemon connection unavailable" })},
		shotState{"sign-in-flows", loginShot(func(m *LoginModel) {
			login, _ := m.signInFor("claude")
			m.startSignIn(login)
		})},
		shotState{"sign-in-field", loginShot(func(m *LoginModel) {
			m.LoginFields = []daemon.FormField{{Type: "secret", Name: "token", Label: "paste the token", Description: "from the provider's keys page"}}
			m.LoginFieldIndex = 0
			m.nextLoginField()
		})},
		shotState{"account-profile", loginShot(func(m *LoginModel) { m.chooseAccount(m.Accounts[0]) })},
		shotState{"api-key", loginShot(func(m *LoginModel) { m.askAPIKey() }, typedKeys("sk-live-abc123")...)},
		shotState{"api-key-error", loginShot(func(m *LoginModel) {
			m.askAPIKey()
			m.Error = "Enter an API key without spaces or control characters."
		})},
		shotState{"base-url", loginShot(func(m *LoginModel) { m.Name = "work"; m.askEndpoint() })},
		shotState{"project", loginShot(func(m *LoginModel) {
			m.Draft.Extension = "vertex"
			m.Name = "vertex"
			m.askProject()
		})},
		shotState{"protocol", loginShot(func(m *LoginModel) {
			m.Step = StepProtocol
			m.buildProtocolPicker()
		})},
		shotState{"browser-wait", loginShot(func(m *LoginModel) {
			m.Step = StepOAuth
			m.Status = "waiting for the browser…"
			m.SignInURL = "https://login.example/authorize?client_id=albedo&state=7f3c"
			m.LoginInstructions = "Finish signing in in your browser."
		})},
		shotState{"device-code", loginShot(func(m *LoginModel) {
			m.Step = StepOAuth
			m.Status = "enter the code to finish"
			m.LoginInstructions = "Open https://login.example/device and enter ABCD-1234."
		})},
		shotState{"models", loginShot(func(m *LoginModel) {
			m.Step = StepModels
			*m, _ = m.Update(loginModelsLoadedMsg{Gen: m.Generation, Models: []string{"gpt-5", "gpt-5-mini", "gpt-4.1"}})
		})},
		shotState{"models-loading", loginShot(func(m *LoginModel) { m.Step = StepModels })},
		shotState{"models-note", loginShot(func(m *LoginModel) {
			m.Step = StepModels
			*m, _ = m.Update(loginModelsLoadedMsg{Gen: m.Generation, Note: "No matching models in models.dev. Enter a model ID manually."})
		})},
		shotState{"saving", loginShot(func(m *LoginModel) { m.Step = StepSaving })},
		shotState{"removing", loginShot(func(m *LoginModel) {
			m.Removing = removal{Kind: "account", Label: "mayer@chernobog"}
			m.Step = StepSaving
		})},
	)
}

// loginModel is the login screen at a terminal size, listing the fixture
// providers, accounts and sign-ins it would list from the daemon.
func loginModel(width, height int) LoginModel {
	m := NewLoginModel(&daemon.Connection{}, "", nil)
	m.SetSize(width, height)
	profiles := config.Profiles{Active: "work", Providers: map[string]config.Settings{
		"work":        {Extension: "openai", Model: "gpt-5", BaseURL: "https://api.openai.com/v1", Protocol: "responses", HasKey: true},
		"claude":      {Extension: "claude", Model: "claude-sonnet-4", Protocol: "chat_completions"},
		"claude-team": {Extension: "claude", Model: "claude-opus-4", Protocol: "chat_completions"},
	}}
	listed := daemon.SignIns{
		Logins: []daemon.SignIn{
			{Provider: "claude", Label: "Claude", Detail: "console billing or your subscription", Protocol: "chat_completions", Flows: []string{"browser", "device"}},
			{Provider: "antigravity", Label: "Antigravity", Detail: "Google account", Flows: []string{"browser"}},
		},
		Accounts: []daemon.Account{{Provider: "claude", ID: "acc-1", Label: "mayer@chernobog", Detail: "Max plan"}},
	}
	m, _ = m.Update(signInsLoadedMsg{Gen: m.Generation, Listed: listed, Profiles: &profiles})
	return m
}

// loginEmpty is the first-run login: nothing saved, so it asks for a name.
func loginEmpty(setup func(*LoginModel)) func(width, height int) string {
	return func(width, height int) string {
		m := NewLoginModel(&daemon.Connection{}, "", nil)
		m.SetSize(width, height)
		m, _ = m.Update(signInsLoadedMsg{Gen: m.Generation, Listed: daemon.SignIns{Logins: []daemon.SignIn{{Provider: "claude", Label: "Claude"}}}, Profiles: &config.Profiles{}})
		if setup != nil {
			setup(&m)
		}
		return m.View()
	}
}

// loginShot draws the login screen after setup and keys.
func loginShot(setup func(*LoginModel), keys ...tea.Msg) func(width, height int) string {
	return func(width, height int) string {
		m := loginModel(width, height)
		if setup != nil {
			setup(&m)
		}
		for _, key := range keys {
			m, _ = m.Update(key)
		}
		return m.View()
	}
}
