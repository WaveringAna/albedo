package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"fmt"
	"maps"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

type LoginDoneMsg struct {
	Name     string
	Settings config.Settings
}

type LoginCancelMsg struct{}

type LoginStep int

const (
	StepChoose LoginStep = iota
	StepName
	StepBaseURL
	StepAPIKey
	StepProtocol
	StepModels
	StepModel
	StepOAuth
	StepOAuthModels
	StepRemove
	StepSaving
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

// signInPollInterval is how often the daemon is asked about a running sign-in.
const signInPollInterval = 300 * time.Millisecond

type loginModelsLoadedMsg struct {
	Models []string
	Note   string
	Err    error
	Gen    int
}

// signInsLoadedMsg carries the daemon's sign-ins and accounts, after the first
// read and after every change to them. Profiles is set when the change also
// rewrote config.json.
type signInsLoadedMsg struct {
	Listed   daemon.SignIns
	Profiles *config.Profiles
	// Keys are the profiles whose api key the daemon holds.
	Keys []string
	Err  error
	Gen  int
}

type signInStartedMsg struct {
	ID  string
	URL string
	Err error
	Gen int
}

type signInStatusMsg struct {
	ID      string
	State   string
	Message string
	Err     error
	Gen     int
}

type signInPollMsg struct {
	ID  string
	Gen int
}

// removal names something /login can delete: a provider in config.json or an
// account in the daemon's credential store.
type removal struct {
	Kind     string // "provider" | "account"
	Provider string
	ID       string // provider name or daemon account id
	Label    string
}

type providerSavedMsg struct {
	Name     string
	Settings config.Settings
	Err      error
}

type LoginModel struct {
	Conn           *daemon.Connection
	Step           LoginStep
	Profiles       config.Profiles
	SignIns        []daemon.SignIn
	Accounts       []daemon.Account
	Hint           string
	Removing       removal
	Name           string
	Draft          config.Settings
	TextInput      textinput.Model
	ChoosePicker   PickerModel
	ProtocolPicker PickerModel
	ModelPicker    PickerModel
	ConfirmPicker  PickerModel
	BrowserOpener  func(url string) // Fail-closed: nil means do not launch browser
	Provider       string           // sign-in provider in flight, or just finished
	LoginID        string           // daemon id of the sign-in in flight
	SignInURL      string
	Status         string // daemon progress line while a sign-in runs
	Catalog        []string
	CatalogNote    string
	Error          string
	Generation     int
	Width          int
	Height         int
	Styles         Styles
}

func (m LoginModel) openBrowserCmd(urlStr string) tea.Cmd {
	return func() tea.Msg {
		// Fail-closed: a nil opener does not launch a browser.
		if m.BrowserOpener != nil {
			m.BrowserOpener(urlStr)
		}
		return nil
	}
}

func NewLoginModel(conn *daemon.Connection, nameHint string) LoginModel {
	profiles, loadErr := config.LoadProfiles(config.HomeDir())

	m := LoginModel{
		Conn:      conn,
		Step:      StepChoose,
		Profiles:  profiles,
		Hint:      strings.TrimSpace(nameHint),
		Draft:     config.Settings{Extension: "openai", BaseURL: "https://api.openai.com/v1", Protocol: "responses"},
		TextInput: newField(),
		Styles:    DefaultStyles,
	}
	if loadErr != nil {
		m.Error = loadErr.Error()
	}
	m.buildChoosePicker()
	return m
}

func (m LoginModel) inputWidth() int {
	// Ink includes its cursor cell in width; Bubbles tracks the cursor separately.
	return pick(m.Step == StepOAuth, max(8, m.Width-25), max(8, m.Width-19))
}

// promptInput re-arms the text input for the next question and reports the
// blink command that shows its cursor. The placeholder is left as the
// previous step left it.
func (m *LoginModel) promptInput(value string, secret bool) tea.Cmd {
	m.TextInput.SetWidth(m.inputWidth())
	return ask(&m.TextInput, value, secret)
}

// pickerFor returns the picker the current step drives.
func (m *LoginModel) pickerFor() *PickerModel {
	switch m.Step {
	case StepProtocol:
		return &m.ProtocolPicker
	case StepRemove:
		return &m.ConfirmPicker
	case StepModels, StepOAuthModels:
		return &m.ModelPicker
	}
	return &m.ChoosePicker
}

// fail shows an error on the current step and keeps waiting for input.
func (m LoginModel) fail(err string) (LoginModel, tea.Cmd) {
	m.Error = err
	return m, nil
}

func (m *LoginModel) SetSize(width, height int) {
	m.Width, m.Height = width, height
	m.TextInput.SetWidth(m.inputWidth())
	m.TextInput.SetValue(m.TextInput.Value())
	for _, p := range []*PickerModel{&m.ChoosePicker, &m.ProtocolPicker, &m.ModelPicker, &m.ConfirmPicker} {
		p.SetSize(width, height)
	}
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
	m.Generation++
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

// signInFor finds the daemon sign-in a profile extension or provider name uses.
func (m LoginModel) signInFor(provider string) (daemon.SignIn, bool) {
	i := slices.IndexFunc(m.SignIns, func(login daemon.SignIn) bool { return login.Provider == provider })
	if i < 0 {
		return daemon.SignIn{}, false
	}
	return m.SignIns[i], true
}

// signedOut reports a sign-in provider with no stored account, which cannot run
// until the user signs in again.
func (m LoginModel) signedOut(provider string) bool {
	if _, known := m.signInFor(provider); !known {
		return false
	}
	return !slices.ContainsFunc(m.Accounts, func(account daemon.Account) bool { return account.Provider == provider })
}

// accountAt resolves a chooser row back to the account it lists.
func (m LoginModel) accountAt(id string) (daemon.Account, bool) {
	index, err := strconv.Atoi(strings.TrimPrefix(id, "account:"))
	if err != nil || index < 0 || index >= len(m.Accounts) {
		return daemon.Account{}, false
	}
	return m.Accounts[index], true
}

func (m *LoginModel) buildChoosePicker() {
	var items []PickerItem
	add := func(id, label, detail string) {
		items = append(items, PickerItem{ID: id, Label: label, Detail: detail})
	}
	for _, name := range slices.Sorted(maps.Keys(m.Profiles.Providers)) {
		settings := m.Profiles.Providers[name]
		extension := cmp.Or(settings.Extension, "openai")
		detail := fmt.Sprintf("%s · %s", settings.Model, extension)
		if _, signIn := m.signInFor(extension); signIn && hasKey(settings) {
			detail += " · API key"
		} else if m.signedOut(extension) {
			detail += " · signed out"
		}
		if name == m.Profiles.Active {
			detail += " · active"
		}
		add("use:"+name, name, detail)
	}
	for index, account := range m.Accounts {
		add("account:"+strconv.Itoa(index), account.Label, account.Detail)
	}
	for _, p := range customProviders {
		add(p.ID, p.Label, p.Detail)
	}
	for _, login := range m.SignIns {
		add("signin:"+login.Provider, login.Label, login.Detail)
	}

	m.ChoosePicker = NewPickerModel("Provider for new sessions", items, false, "use:"+m.Profiles.Active)
	m.ChoosePicker.SetSize(m.Width, m.Height)
}

// removalFor maps a chooser row to what removing it would delete.
func (m LoginModel) removalFor(id string) (removal, bool) {
	if name, ok := strings.CutPrefix(id, "use:"); ok {
		if _, saved := m.Profiles.Providers[name]; saved {
			return removal{Kind: "provider", ID: name, Label: name}, true
		}
	}
	if account, ok := m.accountAt(id); ok {
		return removal{Kind: "account", Provider: account.Provider, ID: account.ID, Label: account.Label}, true
	}
	return removal{}, false
}

func (m *LoginModel) confirmRemoval(target removal) tea.Cmd {
	detail := pick(target.Kind == "account", "This removes its saved tokens", "This removes the provider and its saved key")
	m.Removing = target
	m.Step = StepRemove
	items := []PickerItem{
		{ID: "keep", Label: "keep", Detail: ""},
		{ID: "remove", Label: "remove", Detail: detail},
	}
	m.ConfirmPicker = NewPickerModel(detail+". Remove "+target.Kind+" "+target.Label+"?", items, false, "keep")
	m.ConfirmPicker.SetSize(m.Width, m.Height)
	return m.ConfirmPicker.Init()
}

// reloadCmd changes the daemon's accounts or the saved profiles, then re-reads
// what /login can choose from.
func (m LoginModel) reloadCmd(change func(context.Context) error) tea.Cmd {
	return func() tea.Msg {
		ctx := context.Background()
		if err := change(ctx); err != nil {
			return signInsLoadedMsg{Err: err, Gen: m.Generation}
		}
		profiles, err := config.LoadProfiles(config.HomeDir())
		if err != nil {
			return signInsLoadedMsg{Err: err, Gen: m.Generation}
		}
		msg := m.listSignIns(ctx, m.Generation)
		msg.Profiles = &profiles
		return msg
	}
}

func (m LoginModel) removeCmd(target removal) tea.Cmd {
	return m.reloadCmd(func(ctx context.Context) error {
		if target.Kind == "account" {
			return daemon.RemoveAccount(ctx, m.Conn, target.Provider, target.ID)
		}
		if err := config.RemoveProvider(config.HomeDir(), target.ID); err != nil {
			return err
		}
		return daemon.SetProviderKey(ctx, m.Conn, target.ID, "")
	})
}

func (m LoginModel) selectAccountCmd(account daemon.Account) tea.Cmd {
	return m.reloadCmd(func(ctx context.Context) error {
		return daemon.SelectAccount(ctx, m.Conn, account.Provider, account.ID)
	})
}

func (m *LoginModel) backToChoose() tea.Cmd {
	m.Step = StepChoose
	m.buildChoosePicker()
	return m.ChoosePicker.Init()
}

// startSignIn hands the provider to the daemon, which owns the PKCE pair, the
// callback listener, and the token exchange.
func (m *LoginModel) startSignIn(login daemon.SignIn) tea.Cmd {
	m.Provider = login.Provider
	m.Name = login.Provider
	m.Draft = config.Settings{Extension: login.Provider, Protocol: login.Protocol}
	if saved, ok := m.Profiles.Providers[login.Provider]; ok {
		m.Draft.Model = saved.Model
	}
	m.Step = StepOAuth
	m.Generation++
	// The cursor stays steady here; only the daemon's sign-in command runs.
	m.TextInput.Placeholder = ""
	m.promptInput("", false)
	gen := m.Generation
	return func() tea.Msg {
		started, err := daemon.StartSignIn(context.Background(), m.Conn, login.Provider)
		return signInStartedMsg{ID: started.ID, URL: started.URL, Err: err, Gen: gen}
	}
}

func (m LoginModel) pollSignInCmd(id string, gen int) tea.Cmd {
	return func() tea.Msg {
		status, err := daemon.PollSignIn(context.Background(), m.Conn, id)
		return signInStatusMsg{ID: id, State: status.State, Message: status.Message, Err: err, Gen: gen}
	}
}

func signInPollTickCmd(id string, gen int) tea.Cmd {
	return tea.Tick(signInPollInterval, func(time.Time) tea.Msg {
		return signInPollMsg{ID: id, Gen: gen}
	})
}

func (m LoginModel) inputSignInCmd(id, input string, gen int) tea.Cmd {
	return func() tea.Msg {
		if err := daemon.SignInInput(context.Background(), m.Conn, id, input); err != nil {
			return signInStatusMsg{ID: id, Err: err, Gen: gen}
		}
		return signInPollMsg{ID: id, Gen: gen}
	}
}

// cancelSignInCmd drops a sign-in this client no longer waits for, closing the
// daemon's callback listener.
func (m LoginModel) cancelSignInCmd(id string) tea.Cmd {
	if id == "" || m.Conn == nil {
		return nil
	}
	return func() tea.Msg {
		_ = daemon.CancelSignIn(context.Background(), m.Conn, id)
		return nil
	}
}

// endSignIn forgets the sign-in in flight and returns the command cancelling it.
func (m *LoginModel) endSignIn() tea.Cmd {
	id := m.LoginID
	m.LoginID = ""
	m.SignInURL = ""
	m.Status = ""
	return m.cancelSignInCmd(id)
}

// Close cancels a sign-in still in flight when the login screen goes away.
func (m *LoginModel) Close() tea.Cmd {
	return m.endSignIn()
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

func (m LoginModel) Init() tea.Cmd {
	gen := m.Generation
	return func() tea.Msg { return m.listSignIns(context.Background(), gen) }
}

// listSignIns reads what the daemon can sign in with, the accounts it holds,
// and which profiles it holds an api key for.
func (m LoginModel) listSignIns(ctx context.Context, gen int) signInsLoadedMsg {
	listed, err := daemon.SignInList(ctx, m.Conn)
	if err != nil {
		return signInsLoadedMsg{Err: err, Gen: gen}
	}
	credentials, err := daemon.SavedCredentials(ctx, m.Conn)
	return signInsLoadedMsg{Listed: listed, Keys: credentials.Providers, Err: err, Gen: gen}
}

// hasKey reports a profile with an api key, entered now or held by the daemon.
func hasKey(settings config.Settings) bool {
	return settings.APIKey != "" || settings.HasKey
}

func (m LoginModel) fetchCatalogCmd(ext, endpoint string, gen int) tea.Cmd {
	return func() tea.Msg {
		note := "Could not load the models.dev catalog. Enter a model ID manually."
		if m.Conn == nil {
			return loginModelsLoadedMsg{Note: note, Gen: gen}
		}
		path := fmt.Sprintf("/models/%s?endpoint=%s", url.PathEscape(ext), url.QueryEscape(endpoint))
		names, err := daemon.Request[[]string](context.Background(), m.Conn, path, nil)
		if err != nil {
			return loginModelsLoadedMsg{Err: err, Note: note, Gen: gen}
		}
		if len(names) == 0 {
			note = "No matching models in models.dev. Enter a model ID manually."
		}
		return loginModelsLoadedMsg{Models: names, Note: note, Gen: gen}
	}
}

// saveProviderCmd hands a newly entered api key to the daemon, then saves the
// profile, which config.json keeps without it.
func (m LoginModel) saveProviderCmd(name string, settings config.Settings) tea.Cmd {
	return func() tea.Msg {
		if _, err := settings.Validate(); err != nil {
			return providerSavedMsg{Name: name, Settings: settings, Err: err}
		}
		var err error
		if settings.APIKey != "" {
			err = daemon.SetProviderKey(context.Background(), m.Conn, name, settings.APIKey)
		}
		if err == nil {
			err = config.SaveProvider(config.HomeDir(), name, settings)
		}
		return providerSavedMsg{Name: name, Settings: settings, Err: err}
	}
}

func (m LoginModel) Update(msg tea.Msg) (LoginModel, tea.Cmd) {
	switch msg := msg.(type) {
	case signInsLoadedMsg:
		if msg.Gen != m.Generation {
			return m, nil
		}
		m.SignIns = msg.Listed.Logins
		m.Accounts = msg.Listed.Accounts
		if msg.Profiles != nil {
			m.Profiles = *msg.Profiles
		}
		for _, name := range msg.Keys {
			if settings, ok := m.Profiles.Providers[name]; ok {
				settings.HasKey = true
				m.Profiles.Providers[name] = settings
			}
		}
		if msg.Err != nil && m.Error == "" {
			m.Error = msg.Err.Error()
		}
		if m.Step == StepSaving {
			m.Removing = removal{}
			m.Step = StepChoose
			if msg.Err == nil {
				m.Error = ""
			}
			return m, m.backToChoose()
		}
		m.buildChoosePicker()
		if m.Hint != "" {
			return m, m.applyHint()
		}
		if m.Step != StepChoose {
			return m, nil
		}
		if len(m.Profiles.Providers) == 0 && len(m.Accounts) == 0 {
			m.Step = StepName
			m.TextInput.Placeholder = ""
			return m, m.promptInput("", false)
		}
		return m, m.ChoosePicker.Init()

	case signInStartedMsg:
		if msg.Gen != m.Generation || m.Step != StepOAuth {
			// Stale start: cancel the sign-in this client no longer shows.
			return m, m.cancelSignInCmd(msg.ID)
		}
		if msg.Err != nil {
			m.Error = msg.Err.Error()
			return m, nil
		}
		m.LoginID = msg.ID
		m.SignInURL = msg.URL
		m.Status = ""

		cmds := []tea.Cmd{textinput.Blink}
		if msg.URL != "" {
			cmds = append(cmds, m.openBrowserCmd(msg.URL))
		}
		cmds = append(cmds, m.pollSignInCmd(msg.ID, m.Generation))
		return m, tea.Batch(cmds...)

	case signInPollMsg:
		if msg.Gen != m.Generation || m.Step != StepOAuth || msg.ID != m.LoginID {
			return m, m.cancelSignInCmd(msg.ID)
		}
		return m, m.pollSignInCmd(msg.ID, msg.Gen)

	case signInStatusMsg:
		if msg.Gen != m.Generation || m.Step != StepOAuth || msg.ID != m.LoginID {
			// A stale result: cancel the sign-in this client no longer shows.
			return m, m.cancelSignInCmd(msg.ID)
		}
		if msg.Err != nil {
			m.Error = msg.Err.Error()
			return m, m.endSignIn()
		}
		m.Status = msg.Message
		switch msg.State {
		case "done":
			m.LoginID = ""
			m.Step = StepOAuthModels
			m.Generation++
			return m, m.fetchCatalogCmd(m.Provider, "", m.Generation)
		case "failed":
			m.LoginID = ""
			m.Error = msg.Message
			return m, nil
		default:
			return m, signInPollTickCmd(msg.ID, m.Generation)
		}

	case loginModelsLoadedMsg:
		if msg.Gen != m.Generation || (m.Step != StepModels && m.Step != StepOAuthModels) {
			return m, nil
		}
		m.Catalog = msg.Models
		if m.Catalog == nil {
			m.Catalog = []string{}
		}
		m.CatalogNote = msg.Note
		m.buildModelPicker()
		return m, m.ModelPicker.Init()

	case providerSavedMsg:
		if msg.Err != nil {
			m.Error = msg.Err.Error()
			return m, m.backToChoose()
		}
		return m, func() tea.Msg {
			return LoginDoneMsg{Name: msg.Name, Settings: msg.Settings}
		}

	case tea.KeyPressMsg:
		key := msg.String()
		if m.Step == StepChoose && (key == "delete" || key == "d") {
			if item, ok := m.ChoosePicker.Highlighted(); ok {
				if target, ok := m.removalFor(item.ID); ok {
					return m, m.confirmRemoval(target)
				}
			}
			return m, nil
		}
		if key == "esc" || key == "ctrl+c" || key == "ctrl+d" {
			pickerStep := m.Step == StepChoose || m.Step == StepProtocol || m.Step == StepModels || m.Step == StepOAuthModels || m.Step == StepRemove
			if !pickerStep || key == "ctrl+d" {
				cancel := m.Close()
				m.Generation++
				return m, tea.Batch(cancel, func() tea.Msg { return LoginCancelMsg{} })
			}
		}

	case PickerSelectMsg:
		switch m.Step {
		case StepChoose:
			if p, ok := customProviderByID(msg.ID); ok {
				return m, m.startCustomProvider(p)
			}
			if provider, ok := strings.CutPrefix(msg.ID, "signin:"); ok {
				if login, ok := m.signInFor(provider); ok {
					return m, m.startSignIn(login)
				}
			}
			// Choosing an account selects it; d removes it.
			if account, ok := m.accountAt(msg.ID); ok {
				m.Step = StepSaving
				return m, m.selectAccountCmd(account)
			}
			if name, ok := strings.CutPrefix(msg.ID, "use:"); ok {
				if s, ok := m.Profiles.Providers[name]; ok {
					return m, m.useProfile(name, s)
				}
			}

		case StepRemove:
			if msg.ID == "remove" {
				m.Step = StepSaving
				return m, m.removeCmd(m.Removing)
			}
			return m, m.backToChoose()

		case StepProtocol:
			m.Draft.Protocol = msg.ID
			return m, m.advanceToModels()

		case StepModels, StepOAuthModels:
			if msg.ID == "manual" {
				m.Step = StepModel
				m.TextInput.Placeholder = ""
				return m, m.promptInput("", false)
			}
			if modelName, ok := strings.CutPrefix(msg.ID, "model:"); ok {
				m.Draft.Model = modelName
				m.Step = StepSaving
				return m, m.saveProviderCmd(m.Name, m.Draft)
			}
		}

	case PickerCancelMsg:
		switch m.Step {
		case StepChoose, StepOAuthModels:
			return m, func() tea.Msg { return LoginCancelMsg{} }
		case StepProtocol:
			m.Step = StepAPIKey
			return m, m.promptInput("", true)
		case StepModels:
			m.Generation++
			if m.isFixedProtocol() {
				m.Step = StepAPIKey
				return m, m.promptInput(m.Draft.APIKey, true)
			}
			m.Step = StepBaseURL
			return m, m.promptInput(m.Draft.BaseURL, false)
		case StepRemove:
			return m, m.backToChoose()
		}
	}

	// A picker step routes everything to its picker; the rest to the input.
	switch m.Step {
	case StepChoose, StepProtocol, StepRemove, StepModels, StepOAuthModels:
		p := m.pickerFor()
		var cmd tea.Cmd
		*p, cmd = p.Update(msg)
		return m, cmd
	}

	if key, ok := msg.(tea.KeyPressMsg); ok && key.String() == "enter" {
		switch m.Step {
		case StepName:
			m.TextInput.SetCursor(0)
			name, err := config.ValidateProviderName(strings.TrimSpace(m.TextInput.Value()))
			if err != nil {
				return m.fail(err.Error())
			}
			m.Name = name
			m.Error = ""

			// A name that is a sign-in provider — or a saved profile for one —
			// signs in instead of asking for an api key, unless the profile
			// keeps a key or this is that extension's api-key flow.
			flow := m.Draft.Extension
			extension := name
			if saved, known := m.Profiles.Providers[name]; known {
				extension = saved.Extension
				m.Draft = saved
			}
			if login, ok := m.signInFor(extension); ok && !hasKey(m.Draft) && extension != flow {
				return m, m.startSignIn(login)
			}
			return m, m.askEndpoint()

		case StepBaseURL:
			m.TextInput.SetCursor(0)
			val := cmp.Or(strings.TrimSpace(m.TextInput.Value()), m.Draft.BaseURL)
			endpoint, err := config.ValidateEndpoint(val)
			if err != nil {
				return m.fail(err.Error())
			}
			if endpoint != m.Draft.BaseURL {
				m.Draft.APIKey, m.Draft.HasKey = "", false
			}
			m.Draft.BaseURL = endpoint
			m.Error = ""
			m.Step = StepAPIKey
			m.TextInput.Placeholder = ""
			return m, m.promptInput("", true)

		case StepAPIKey:
			m.TextInput.SetCursor(0)
			switch val := cmp.Or(m.TextInput.Value(), m.Draft.APIKey); {
			case val == "" && m.Draft.HasKey:
				// Blank keeps the key the daemon holds.
			case val == "" || strings.ContainsFunc(val, func(r rune) bool { return r <= 0x20 || r == 0x7f }):
				return m.fail("Enter an API key without spaces or control characters.")
			default:
				m.Draft.APIKey = val
			}
			m.Error = ""
			if m.isFixedProtocol() {
				return m, m.advanceToModels()
			}
			m.Step = StepProtocol
			m.buildProtocolPicker()
			return m, m.ProtocolPicker.Init()

		case StepOAuth:
			val := strings.TrimSpace(m.TextInput.Value())
			if val != "" && m.LoginID != "" {
				m.Status = "exchanging authorization code…"
				m.Error = ""
				return m, m.inputSignInCmd(m.LoginID, val, m.Generation)
			}

		case StepModel:
			m.TextInput.SetCursor(0)
			val := strings.TrimSpace(m.TextInput.Value())
			if err := validateModelID(val); err != nil {
				return m.fail(err.Error())
			}
			m.Draft.Model = val
			m.Error = ""
			m.Step = StepSaving
			return m, m.saveProviderCmd(m.Name, m.Draft)
		}
	}

	var cmd tea.Cmd
	m.TextInput, cmd = m.TextInput.Update(msg)
	return m, cmd
}

func (m LoginModel) View() string {
	var b strings.Builder
	line := func(s string) {
		b.WriteString(s)
		b.WriteByte('\n')
	}
	line(titleRule(m.Width, brand("albedo")+" "+m.Styles.Muted.Render("/login"), m.Styles.Faint.Render(m.Name)))
	location := "Provider configuration stored in " + config.HomeDir()
	if m.Width > 0 && ansi.StringWidth(location) > m.Width && ansi.StringWidth(config.HomeDir()) <= m.Width {
		location = "Provider configuration stored in\n" + config.HomeDir()
	}
	line(m.Styles.Faint.Render(ansi.Wrap(location, m.Width, "")))
	if m.Error != "" {
		line(m.Styles.Error.Render(ansi.Wrap(m.Error, m.Width, "")))
	}

	switch m.Step {
	case StepChoose:
		line(m.ChoosePicker.View())
		b.WriteString(ansi.Wrap(keyHints(hint{"enter", "select"}, hint{"d", "remove"}, hint{"esc", "cancel"}), m.Width, ""))
	case StepProtocol:
		b.WriteString(m.ProtocolPicker.View())
	case StepRemove:
		b.WriteString(m.ConfirmPicker.View())
	case StepModels, StepOAuthModels:
		if m.Catalog == nil {
			b.WriteString(m.Styles.Faint.Render("loading models…"))
			break
		}
		if m.CatalogNote != "" {
			line(m.Styles.Faint.Render(m.CatalogNote))
		}
		b.WriteString(m.ModelPicker.View())
	case StepOAuth:
		line(cmp.Or(m.Status, "starting sign-in…"))
		if m.SignInURL != "" {
			line(m.Styles.Faint.Render(ansi.Hardwrap(m.SignInURL, m.Width, true)))
		}
		b.WriteString("Callback URL or code: ")
		line(m.TextInput.View())
		b.WriteString(ansi.Wrap(m.Styles.Faint.Render("Browser sign-in completes automatically")+m.Styles.Decor.Render(" · ")+keyHints(hint{"enter", "submit code"}, hint{"esc", "cancel"}), m.Width, ""))
	case StepSaving:
		state := pick(m.Removing.Kind != "", "removing "+m.Removing.Kind+"…", "saving provider…")
		b.WriteString(m.Styles.Faint.Render(state))
	default:
		stepLabels := map[LoginStep]string{
			StepName: "provider name", StepBaseURL: "API base URL",
			StepAPIKey: "API key", StepModel: "model ID",
		}
		line(stepLabels[m.Step] + ": " + m.TextInput.View())
		var hints []hint
		if m.Step == StepAPIKey && m.Draft.APIKey != "" {
			hints = append(hints, hint{"enter", "keeps the saved key"})
		}
		if m.Step == StepName {
			for _, login := range m.SignIns {
				hints = append(hints, hint{"", "use " + login.Provider + " to sign in"})
			}
		}
		hints = append(hints, hint{"enter", "continue"}, hint{"esc", "cancel"})
		b.WriteString(ansi.Wrap(keyHints(hints...), m.Width, ""))
	}
	return b.String()
}
