package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"context"
	"fmt"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/cursor"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
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
}

var customProviders = []customProvider{
	{
		ID:            "add-alibaba",
		Label:         "add or update alibaba provider",
		Detail:        "token plan · qwen, deepseek, glm",
		Extension:     "alibaba",
		DefaultName:   "alibaba",
		DefaultURL:    "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
		FixedProtocol: "chat_completions",
	},
	{
		ID:         "add-openai",
		Label:      "add or update openai-compatible provider",
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

func customProviderByExtension(ext string) (customProvider, bool) {
	for _, p := range customProviders {
		if p.Extension == ext {
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
	Err      error
	Gen      int
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
		m.openBrowser(urlStr)
		return nil
	}
}

func (m LoginModel) openBrowser(urlStr string) {
	if m.BrowserOpener != nil {
		m.BrowserOpener(urlStr)
	}
	// Fail-closed by default: nil opener does NOT launch a browser.
}

func NewLoginModel(conn *daemon.Connection, nameHint string) LoginModel {
	profiles, loadErr := config.LoadProfiles(config.HomeDir())

	ti := textinput.New()
	ti.Prompt = ""
	ti.Cursor.SetMode(cursor.CursorStatic)

	m := LoginModel{
		Conn:      conn,
		Step:      StepChoose,
		Profiles:  profiles,
		Hint:      strings.TrimSpace(nameHint),
		Draft:     config.Settings{Extension: "openai", BaseURL: "https://api.openai.com/v1", Protocol: "responses"},
		TextInput: ti,
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
	if m.Step == StepOAuth {
		return max(8, m.Width-25)
	}
	return max(8, m.Width-19)
}

func (m *LoginModel) resetInput() {
	m.TextInput.Reset()
	m.TextInput.EchoMode = textinput.EchoNormal
	m.TextInput.Width = m.inputWidth()
}

func (m *LoginModel) SetSize(width, height int) {
	m.Width = width
	m.Height = height
	m.TextInput.Width = m.inputWidth()
	m.TextInput.SetValue(m.TextInput.Value())
	m.ChoosePicker.SetSize(width, height)
	m.ProtocolPicker.SetSize(width, height)
	m.ModelPicker.SetSize(width, height)
	m.ConfirmPicker.SetSize(width, height)
}

func (m LoginModel) isFixedProtocol() bool {
	p, ok := customProviderByExtension(m.Draft.Extension)
	return ok && p.FixedProtocol != ""
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
	proto := p.FixedProtocol
	if proto == "" {
		proto = "responses"
	}
	m.Draft = config.Settings{Extension: p.Extension, BaseURL: p.DefaultURL, Protocol: proto}
	m.Step = StepName
	m.resetInput()
	m.TextInput.Placeholder = p.DefaultName
	m.TextInput.Focus()
	return textinput.Blink
}

// signInFor finds the daemon sign-in a profile extension or provider name uses.
func (m LoginModel) signInFor(provider string) (daemon.SignIn, bool) {
	for _, login := range m.SignIns {
		if login.Provider == provider {
			return login, true
		}
	}
	return daemon.SignIn{}, false
}

// signedOut reports a sign-in provider with no stored account, which cannot run
// until the user signs in again.
func (m LoginModel) signedOut(provider string) bool {
	if _, known := m.signInFor(provider); !known {
		return false
	}
	for _, account := range m.Accounts {
		if account.Provider == provider {
			return false
		}
	}
	return true
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
	names := make([]string, 0, len(m.Profiles.Providers))
	for name := range m.Profiles.Providers {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		settings := m.Profiles.Providers[name]
		extension := settings.Extension
		if extension == "" {
			extension = "openai"
		}
		detail := fmt.Sprintf("%s · %s", settings.Model, extension)
		if m.signedOut(extension) {
			detail += " · signed out"
		}
		if name == m.Profiles.Active {
			detail += " · active"
		}
		items = append(items, PickerItem{
			ID:     "use:" + name,
			Label:  name,
			Detail: detail,
		})
	}
	for index, account := range m.Accounts {
		items = append(items, PickerItem{
			ID:     "account:" + strconv.Itoa(index),
			Label:  account.Label,
			Detail: account.Detail,
		})
	}
	for _, p := range customProviders {
		items = append(items, PickerItem{
			ID:     p.ID,
			Label:  p.Label,
			Detail: p.Detail,
		})
	}
	for _, login := range m.SignIns {
		items = append(items, PickerItem{
			ID:     "signin:" + login.Provider,
			Label:  login.Label,
			Detail: login.Detail,
		})
	}

	initialSel := "use:" + m.Profiles.Active
	m.ChoosePicker = NewPickerModel("provider for new sessions", items, false, initialSel)
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
	detail := "deletes it from config.json"
	if target.Kind == "account" {
		detail = "deletes its tokens from auth.json"
	}
	m.Removing = target
	m.Step = StepRemove
	items := []PickerItem{
		{ID: "keep", Label: "keep", Detail: ""},
		{ID: "remove", Label: "remove", Detail: detail},
	}
	m.ConfirmPicker = NewPickerModel("remove "+target.Kind+" "+target.Label+"?", items, false, "keep")
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
		listed, err := daemon.SignInList(ctx, m.Conn)
		return signInsLoadedMsg{Listed: listed, Profiles: &profiles, Err: err, Gen: m.Generation}
	}
}

func (m LoginModel) removeCmd(target removal) tea.Cmd {
	return m.reloadCmd(func(ctx context.Context) error {
		if target.Kind == "account" {
			return daemon.RemoveAccount(ctx, m.Conn, target.Provider, target.ID)
		}
		return config.RemoveProvider(config.HomeDir(), target.ID)
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

func (m LoginModel) loadSignInsCmd(gen int) tea.Cmd {
	return func() tea.Msg {
		listed, err := daemon.SignInList(context.Background(), m.Conn)
		return signInsLoadedMsg{Listed: listed, Err: err, Gen: gen}
	}
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
	m.resetInput()
	m.TextInput.Placeholder = ""
	m.TextInput.Focus()
	m.Generation++
	return m.startSignInCmd(login.Provider, m.Generation)
}

func (m LoginModel) startSignInCmd(provider string, gen int) tea.Cmd {
	return func() tea.Msg {
		started, err := daemon.StartSignIn(context.Background(), m.Conn, provider)
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
		if login, ok := m.signInFor(saved.Extension); ok && m.signedOut(saved.Extension) {
			return m.startSignIn(login)
		}
		m.Draft = saved
		m.Step = StepSaving
		return m.saveProviderCmd(name, saved)
	}
	if login, ok := m.signInFor(name); ok {
		return m.startSignIn(login)
	}
	m.Step = StepBaseURL
	m.resetInput()
	m.TextInput.SetValue(m.Draft.BaseURL)
	m.TextInput.Focus()
	return textinput.Blink
}

func (m *LoginModel) buildProtocolPicker() {
	items := []PickerItem{
		{ID: "responses", Label: "responses", Detail: "openai responses api"},
		{ID: "chat_completions", Label: "chat completions", Detail: "widely supported by compatible endpoints"},
	}
	m.ProtocolPicker = NewPickerModel("api protocol", items, false, m.Draft.Protocol)
	m.ProtocolPicker.SetSize(m.Width, m.Height)
}

func (m *LoginModel) buildModelPicker() {
	var items []PickerItem
	for _, name := range m.Catalog {
		items = append(items, PickerItem{
			ID:     "model:" + name,
			Label:  name,
			Detail: "",
		})
	}
	items = append(items, PickerItem{
		ID:     "manual",
		Label:  "enter model id manually",
		Detail: "",
	})

	initialSel := "model:" + m.Draft.Model
	m.ModelPicker = NewPickerModel("model", items, true, initialSel)
	m.ModelPicker.SetSize(m.Width, m.Height)
}

func (m LoginModel) Init() tea.Cmd {
	return m.loadSignInsCmd(m.Generation)
}

func (m LoginModel) fetchCatalogCmd(ext, endpoint string, gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return loginModelsLoadedMsg{
				Note: "could not read the models.dev catalog; enter a model id",
				Gen:  gen,
			}
		}

		path := fmt.Sprintf("/models/%s?endpoint=%s", url.PathEscape(ext), url.QueryEscape(endpoint))
		names, err := daemon.Request[[]string](context.Background(), m.Conn, path, nil)
		if err != nil {
			return loginModelsLoadedMsg{
				Models: nil,
				Note:   "could not read the models.dev catalog; enter a model id",
				Err:    err,
				Gen:    gen,
			}
		}
		var note string
		if len(names) == 0 {
			note = "models.dev has no matching models; enter a model id"
		}
		return loginModelsLoadedMsg{Models: names, Note: note, Gen: gen}
	}
}

func (m LoginModel) saveProviderCmd(name string, settings config.Settings) tea.Cmd {
	return func() tea.Msg {
		home := config.HomeDir()
		if err := config.SaveProvider(home, name, settings); err != nil {
			return providerSavedMsg{Name: name, Settings: settings, Err: err}
		}
		return providerSavedMsg{Name: name, Settings: settings}
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
			m.resetInput()
			m.TextInput.Placeholder = ""
			m.TextInput.Focus()
			return m, textinput.Blink
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
			m.Step = StepChoose
			m.buildChoosePicker()
			return m, m.ChoosePicker.Init()
		}
		return m, func() tea.Msg {
			return LoginDoneMsg{Name: msg.Name, Settings: msg.Settings}
		}

	case tea.KeyMsg:
		if m.Step == StepChoose && (msg.Type == tea.KeyDelete || msg.String() == "d") {
			if item, ok := m.ChoosePicker.Highlighted(); ok {
				if target, ok := m.removalFor(item.ID); ok {
					return m, m.confirmRemoval(target)
				}
			}
			return m, nil
		}
		if msg.Type == tea.KeyEsc || msg.Type == tea.KeyCtrlC || msg.Type == tea.KeyCtrlD {
			pickerStep := m.Step == StepChoose || m.Step == StepProtocol || m.Step == StepModels || m.Step == StepOAuthModels || m.Step == StepRemove
			if !pickerStep || msg.Type == tea.KeyCtrlD {
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
			if strings.HasPrefix(msg.ID, "use:") {
				name := strings.TrimPrefix(msg.ID, "use:")
				if s, ok := m.Profiles.Providers[name]; ok {
					// A sign-in provider with no accounts left cannot run; sign in first.
					if login, ok := m.signInFor(s.Extension); ok && m.signedOut(s.Extension) {
						return m, m.startSignIn(login)
					}
					m.Step = StepSaving
					return m, m.saveProviderCmd(name, s)
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
				m.resetInput()
				m.TextInput.Placeholder = ""
				m.TextInput.Focus()
				return m, textinput.Blink
			}
			if modelName, ok := strings.CutPrefix(msg.ID, "model:"); ok {
				m.Draft.Model = modelName
				m.Step = StepSaving
				return m, m.saveProviderCmd(m.Name, m.Draft)
			}
		}

	case PickerCancelMsg:
		if m.Step == StepChoose {
			return m, func() tea.Msg { return LoginCancelMsg{} }
		}
		if m.Step == StepProtocol {
			m.Step = StepAPIKey
			m.resetInput()
			m.TextInput.EchoMode = textinput.EchoPassword
			m.TextInput.Focus()
			return m, textinput.Blink
		}
		if m.Step == StepModels {
			m.Generation++
			if m.isFixedProtocol() {
				m.Step = StepAPIKey
				m.resetInput()
				m.TextInput.EchoMode = textinput.EchoPassword
				m.TextInput.SetValue(m.Draft.APIKey)
				m.TextInput.Focus()
				return m, textinput.Blink
			}
			m.Step = StepBaseURL
			m.resetInput()
			m.TextInput.SetValue(m.Draft.BaseURL)
			m.TextInput.Focus()
			return m, textinput.Blink
		}
		if m.Step == StepOAuthModels {
			return m, func() tea.Msg { return LoginCancelMsg{} }
		}
		if m.Step == StepRemove {
			return m, m.backToChoose()
		}
	}

	// Handle input submissions per step
	switch m.Step {
	case StepChoose:
		var cmd tea.Cmd
		m.ChoosePicker, cmd = m.ChoosePicker.Update(msg)
		return m, cmd

	case StepProtocol:
		var cmd tea.Cmd
		m.ProtocolPicker, cmd = m.ProtocolPicker.Update(msg)
		return m, cmd

	case StepRemove:
		var cmd tea.Cmd
		m.ConfirmPicker, cmd = m.ConfirmPicker.Update(msg)
		return m, cmd

	case StepModels, StepOAuthModels:
		var cmd tea.Cmd
		m.ModelPicker, cmd = m.ModelPicker.Update(msg)
		return m, cmd

	case StepName:
		if keyMsg, ok := msg.(tea.KeyMsg); ok && keyMsg.Type == tea.KeyEnter {
			val := strings.TrimSpace(m.TextInput.Value())
			m.TextInput.SetCursor(0)
			name, err := config.ValidateProviderName(val)
			if err != nil {
				m.Error = err.Error()
				return m, nil
			}
			m.Name = name
			m.Error = ""

			// A name that is a sign-in provider — or a saved profile for one —
			// signs in instead of asking for an api key.
			extension := name
			if saved, known := m.Profiles.Providers[name]; known {
				extension = saved.Extension
				m.Draft = saved
			}
			if login, ok := m.signInFor(extension); ok {
				return m, m.startSignIn(login)
			}

			m.Step = StepBaseURL
			m.resetInput()
			m.TextInput.SetValue(m.Draft.BaseURL)
			m.TextInput.Focus()
			return m, textinput.Blink
		}

	case StepBaseURL:
		if keyMsg, ok := msg.(tea.KeyMsg); ok && keyMsg.Type == tea.KeyEnter {
			val := strings.TrimSpace(m.TextInput.Value())
			m.TextInput.SetCursor(0)
			if val == "" {
				val = m.Draft.BaseURL
			}
			endpoint, err := config.ValidateEndpoint(val)
			if err != nil {
				m.Error = err.Error()
				return m, nil
			}
			if endpoint != m.Draft.BaseURL {
				m.Draft.APIKey = ""
			}
			m.Draft.BaseURL = endpoint
			m.Error = ""
			m.Step = StepAPIKey
			m.resetInput()
			m.TextInput.EchoMode = textinput.EchoPassword
			m.TextInput.Placeholder = ""
			m.TextInput.Focus()
			return m, textinput.Blink
		}

	case StepAPIKey:
		if keyMsg, ok := msg.(tea.KeyMsg); ok && keyMsg.Type == tea.KeyEnter {
			val := m.TextInput.Value()
			m.TextInput.SetCursor(0)
			if val == "" && m.Draft.APIKey != "" {
				val = m.Draft.APIKey
			}
			if val == "" {
				m.Error = "enter an api key without spaces or control characters"
				return m, nil
			}
			for _, r := range val {
				if r <= 0x20 || r == 0x7f {
					m.Error = "enter an api key without spaces or control characters"
					return m, nil
				}
			}
			m.Draft.APIKey = val
			m.Error = ""
			if m.isFixedProtocol() {
				return m, m.advanceToModels()
			}
			m.Step = StepProtocol
			m.buildProtocolPicker()
			return m, m.ProtocolPicker.Init()
		}

	case StepOAuth:
		if keyMsg, ok := msg.(tea.KeyMsg); ok && keyMsg.Type == tea.KeyEnter {
			val := strings.TrimSpace(m.TextInput.Value())
			if val != "" && m.LoginID != "" {
				m.Status = "exchanging authorization code…"
				m.Error = ""
				return m, m.inputSignInCmd(m.LoginID, val, m.Generation)
			}
		}

	case StepModel:
		if keyMsg, ok := msg.(tea.KeyMsg); ok && keyMsg.Type == tea.KeyEnter {
			val := strings.TrimSpace(m.TextInput.Value())
			m.TextInput.SetCursor(0)
			if err := validateModelID(val); err != nil {
				m.Error = err.Error()
				return m, nil
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
	b.WriteString(titleRule(m.Width, brand("albedo")+" "+m.Styles.Muted.Render("/login"), m.Styles.Faint.Render(m.Name)))
	b.WriteByte('\n')
	location := "model auth extensions · saved in " + config.HomeDir()
	if m.Width > 0 && ansi.StringWidth(location) > m.Width && ansi.StringWidth(config.HomeDir()) <= m.Width {
		location = "model auth extensions · saved in\n" + config.HomeDir()
	}
	b.WriteString(m.Styles.Faint.Render(ansi.Wrap(location, m.Width, "")))
	b.WriteByte('\n')
	if m.Error != "" {
		b.WriteString(m.Styles.Error.Render(ansi.Wrap(m.Error, m.Width, "")))
		b.WriteByte('\n')
	}

	switch m.Step {
	case StepChoose:
		b.WriteString(m.ChoosePicker.View())
		b.WriteByte('\n')
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
			b.WriteString(m.Styles.Faint.Render(m.CatalogNote))
			b.WriteByte('\n')
		}
		b.WriteString(m.ModelPicker.View())
	case StepOAuth:
		status := m.Status
		if status == "" {
			status = "starting sign-in…"
		}
		b.WriteString(status)
		b.WriteByte('\n')
		if m.SignInURL != "" {
			b.WriteString(m.Styles.Faint.Render(ansi.Hardwrap(m.SignInURL, m.Width, true)))
			b.WriteByte('\n')
		}
		b.WriteString("callback url or code: ")
		b.WriteString(m.TextInput.View())
		b.WriteByte('\n')
		b.WriteString(ansi.Wrap(m.Styles.Faint.Render("browser callback completes automatically")+m.Styles.Decor.Render(" · ")+keyHints(hint{"enter", "pastes manually"}, hint{"esc", "cancel"}), m.Width, ""))
	case StepSaving:
		if m.Removing.Kind != "" {
			b.WriteString(m.Styles.Faint.Render("removing " + m.Removing.Kind + "…"))
			break
		}
		b.WriteString(m.Styles.Faint.Render("saving provider…"))
	default:
		stepLabels := map[LoginStep]string{
			StepName: "provider name", StepBaseURL: "api base url",
			StepAPIKey: "api key", StepModel: "model id",
		}
		b.WriteString(stepLabels[m.Step] + ": ")
		b.WriteString(m.TextInput.View())
		b.WriteByte('\n')
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
