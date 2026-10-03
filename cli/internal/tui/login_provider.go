package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"slices"

	tea "charm.land/bubbletea/v2"
)

type customProvider struct {
	ID            string
	Label         string
	Detail        string
	Extension     string
	DefaultName   string
	DefaultURL    string
	FixedProtocol string
	// FixedEndpoint skips the base url: the extension knows where it sends.
	FixedEndpoint bool
}

var customProviders = []customProvider{
	{
		ID:            "add-alibaba",
		Label:         "add or update an Alibaba provider",
		Detail:        "token plan · Qwen, DeepSeek, GLM",
		Extension:     "alibaba",
		DefaultName:   "alibaba",
		DefaultURL:    "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
		FixedProtocol: "chat_completions",
	},
	{
		ID:            "add-anthropic",
		Label:         "add or update an Anthropic API key",
		Detail:        "console billing · Claude models",
		Extension:     "claude",
		DefaultName:   "anthropic",
		FixedProtocol: "chat_completions",
		FixedEndpoint: true,
	},
	{
		ID:         "add-openai",
		Label:      "add or update an OpenAI-compatible provider",
		Extension:  "openai",
		DefaultURL: "https://api.openai.com/v1",
	},
}

func customProviderByID(id string) (customProvider, bool) {
	for _, p := range customProviders {
		if p.ID == id {
			return p, true
		}
	}
	return customProvider{}, false
}

// custom finds the api-key provider the draft's extension belongs to.
func (m LoginModel) custom() (customProvider, bool) {
	i := slices.IndexFunc(customProviders, func(p customProvider) bool { return p.Extension == m.Draft.Extension })
	if i < 0 {
		return customProvider{}, false
	}
	return customProviders[i], true
}

func (m LoginModel) isFixedProtocol() bool {
	p, ok := m.custom()
	return ok && p.FixedProtocol != ""
}

// askEndpoint asks for the base url, or straight for the api key when the
// extension has a fixed endpoint.
func (m *LoginModel) askEndpoint() tea.Cmd {
	if p, ok := m.custom(); ok && p.FixedEndpoint {
		m.Step = StepAPIKey
		m.TextInput.Placeholder = ""
		return m.promptInput("", true)
	}
	m.Step = StepBaseURL
	return m.promptInput(m.Draft.BaseURL, false)
}

func (m *LoginModel) advanceToModels() tea.Cmd {
	m.Catalog = nil
	m.CatalogNote = ""
	m.Step = StepModels
	m.Generation = nextPageGeneration()
	return m.fetchCatalogCmd(m.Draft.Extension, m.Draft.BaseURL, m.Generation)
}

func (m *LoginModel) startCustomProvider(p customProvider) tea.Cmd {
	m.Name = p.DefaultName
	m.Draft = config.Settings{Extension: p.Extension, BaseURL: p.DefaultURL, Protocol: cmp.Or(p.FixedProtocol, "responses")}
	m.Step = StepName
	m.TextInput.Placeholder = p.DefaultName
	return m.promptInput("", false)
}

// useProfile re-selects a saved profile: a sign-in provider with no accounts
// left cannot run without an api key, so it signs in first.
func (m *LoginModel) useProfile(name string, settings config.Settings) tea.Cmd {
	if login, ok := m.signInFor(settings.Extension); ok && !hasKey(settings) && m.signedOut(settings.Extension) {
		return m.startSignIn(login)
	}
	m.Step = StepSaving
	return m.saveProviderCmd(name, settings)
}

// applyHint routes a name given to `/login <name>`: a saved profile is chosen as
// it stands, a sign-in provider starts its sign-in, anything else is a new
// openai-compatible provider.
func (m *LoginModel) applyHint() tea.Cmd {
	hint := m.Hint
	m.Hint = ""
	name, err := config.ValidateProviderName(hint)
	if err != nil {
		m.Error = err.Error()
		m.Step = StepChoose
		return m.ChoosePicker.Init()
	}
	m.Name = name
	if saved, ok := m.Profiles.Providers[name]; ok {
		m.Draft = saved
		return m.useProfile(name, saved)
	}
	if login, ok := m.signInFor(name); ok {
		return m.startSignIn(login)
	}
	return m.askEndpoint()
}

func (m *LoginModel) buildProtocolPicker() {
	items := []PickerItem{
		{ID: "responses", Label: "responses", Detail: "OpenAI Responses API"},
		{ID: "chat_completions", Label: "chat completions", Detail: "widely supported by compatible endpoints"},
	}
	m.ProtocolPicker = NewPickerModel("api protocol", items, false, m.Draft.Protocol)
	m.ProtocolPicker.SetSize(m.Width, m.Height)
}

func (m *LoginModel) buildModelPicker() {
	items := make([]PickerItem, 0, len(m.Catalog)+1)
	for _, name := range m.Catalog {
		items = append(items, PickerItem{ID: "model:" + name, Label: name})
	}
	items = append(items, PickerItem{ID: "manual", Label: "enter a model ID manually"})

	m.ModelPicker = NewPickerModel("model", items, true, "model:"+m.Draft.Model)
	m.ModelPicker.SetSize(m.Width, m.Height)
}

// hasKey reports a profile with an api key, entered now or held by the daemon.
func hasKey(settings config.Settings) bool {
	return settings.APIKey != "" || settings.HasKey
}

func (m LoginModel) fetchCatalogCmd(ext, endpoint string, gen int) tea.Cmd {
	return func() tea.Msg {
		note := ""
		if m.Conn == nil {
			return loginModelsLoadedMsg{Note: "Could not load the models.dev catalog. Enter a model ID manually.", Gen: gen}
		}
		models, err := daemon.ListModels(m.readCtx, m.Conn, ext, endpoint)
		names := make([]string, len(models))
		for i, model := range models {
			names[i] = model.ID
		}
		if err != nil {
			return loginModelsLoadedMsg{Err: err, Note: "Could not load the models.dev catalog. Enter a model ID manually.", Gen: gen}
		}
		if len(names) == 0 {
			note = "No matching models in models.dev. Enter a model ID manually."
		}
		return loginModelsLoadedMsg{Models: names, Note: note, Gen: gen}
	}
}

// saveProviderCmd saves the profile and optional key through the daemon.
func (m LoginModel) saveProviderCmd(name string, settings config.Settings) tea.Cmd {
	return func() tea.Msg {
		validated, err := settings.Validate()
		if err != nil {
			return providerSavedMsg{Gen: m.Generation, Name: name, Settings: settings, Err: err}
		}
		err = daemon.SaveAndSelectProvider(context.Background(), m.Conn, name, validated, m.Profiles.ETag)
		return providerSavedMsg{Gen: m.Generation, Name: name, Settings: validated, Err: err}
	}
}
