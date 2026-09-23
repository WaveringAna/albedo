package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/cursor"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
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
	StepCodexAuth
	StepCodexModels
	StepRemove
	StepSaving
)

type loginModelsLoadedMsg struct {
	Models []string
	Note   string
	Err    error
	Gen    int
}

type codexAuthStartedMsg struct {
	Verifier string
	State    string
	AuthURL  string
	Ctx      context.Context
	Cancel   context.CancelFunc
	Close    func()
	CodeChan <-chan string
	ErrChan  <-chan error
	Gen      int
}

type codexAuthExchangedMsg struct {
	Cred   *config.CodexCredential
	Models []string
	Err    error
	Gen    int
}

// removal names something saved that /login can delete: a provider in
// config.json or a ChatGPT account in auth.json.
type removal struct {
	Kind  string // "provider" | "account"
	ID    string // provider name or credential identity
	Label string
}

// storedMsg carries profiles and accounts reloaded after /login changed them.
type storedMsg struct {
	Profiles config.Profiles
	Accounts []config.CodexCredential
	Err      error
}

type providerSavedMsg struct {
	Name     string
	Settings config.Settings
	Err      error
}

type LoginModel struct {
	Conn             *daemon.Connection
	Step             LoginStep
	Profiles         config.Profiles
	Accounts         []config.CodexCredential
	Removing         removal
	Name             string
	Kind             string // "openai" | "codex"
	Draft            config.Settings
	TextInput        textinput.Model
	ChoosePicker     PickerModel
	ProtocolPicker   PickerModel
	ModelPicker      PickerModel
	ConfirmPicker    PickerModel
	BrowserOpener    func(url string) // Fail-closed: nil means do not launch browser
	ExchangeCodeFunc func(ctx context.Context, client *http.Client, code, verifier string) (*config.CodexCredential, error)
	CodexVerifier    string
	CodexState       string
	CodexAuthURL     string
	CodexStatus      string
	CodexClose       func()
	CodexCancel      context.CancelFunc
	CodexManualChan  chan string
	Catalog          []string
	CatalogNote      string
	Error            string
	Generation       int
	Width            int
	Height           int
	Styles           Styles
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
	home := config.HomeDir()
	profiles, loadErr := config.LoadProfiles(home)

	ti := textinput.New()
	ti.Prompt = ""
	ti.Cursor.SetMode(cursor.CursorStatic)

	emptyDraft := config.Settings{
		Extension: "openai",
		BaseURL:   "https://api.openai.com/v1",
		Protocol:  "responses",
	}

	m := LoginModel{
		Conn:      conn,
		Profiles:  profiles,
		Draft:     emptyDraft,
		TextInput: ti,
		Styles:    DefaultStyles,
	}
	if loadErr != nil {
		m.Error = loadErr.Error()
		m.Step = StepChoose
		m.buildChoosePicker()
		return m
	}
	accounts, accountsErr := config.LoadCodexAccounts(home)
	if accountsErr != nil {
		m.Error = accountsErr.Error()
	}
	m.Accounts = accounts

	if nameHint != "" {
		cleanName, err := config.ValidateProviderName(nameHint)
		if err != nil {
			m.Error = err.Error()
			m.Step = StepChoose
			m.buildChoosePicker()
			return m
		}
		if s, ok := profiles.Providers[cleanName]; ok && !(s.IsCodex() && len(accounts) == 0) {
			m.Name = cleanName
			m.Draft = s
			m.Step = StepSaving
			return m
		}
		if s, ok := profiles.Providers[cleanName]; cleanName == "codex" || (ok && s.IsCodex()) {
			m.Kind = "codex"
			m.Name = cleanName
			m.Step = StepCodexAuth
			m.TextInput.Focus()
			return m
		}
		m.Name = cleanName
		m.Kind = "openai"
		m.Step = StepBaseURL
		m.resetInput()
		m.TextInput.SetValue(emptyDraft.BaseURL)
		m.TextInput.Focus()
		return m
	}

	if len(profiles.Providers) > 0 || len(accounts) > 0 {
		m.Step = StepChoose
		m.buildChoosePicker()
	} else {
		m.Step = StepName
		m.resetInput()
		m.TextInput.Placeholder = ""
		m.TextInput.Focus()
	}

	return m
}

func (m LoginModel) inputWidth() int {
	// Ink includes its cursor cell in width; Bubbles tracks the cursor separately.
	if m.Step == StepCodexAuth {
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

func (m *LoginModel) cancelCodex() {
	if m.CodexClose != nil {
		m.CodexClose()
		m.CodexClose = nil
	}
	if m.CodexCancel != nil {
		m.CodexCancel()
		m.CodexCancel = nil
	}
	m.CodexManualChan = nil
}

func (m LoginModel) startCodexCmd(gen int) tea.Cmd {
	return func() tea.Msg {
		verifier, state, authURL := config.CreateAuthorization()
		ctx, cancel := context.WithCancel(context.Background())

		listener, codeChan, errChan, closeServer := config.StartCallbackServer(ctx, state)
		if listener == nil {
			codeChan = nil
		}

		return codexAuthStartedMsg{
			Verifier: verifier,
			State:    state,
			AuthURL:  authURL,
			Ctx:      ctx,
			Cancel:   cancel,
			Close:    closeServer,
			CodeChan: codeChan,
			ErrChan:  errChan,
			Gen:      gen,
		}
	}
}

func (m LoginModel) waitForCodexAuthCmd(ctx context.Context, codeChan <-chan string, errChan <-chan error, manualChan <-chan string, verifier, state string, gen int) tea.Cmd {
	return func() tea.Msg {
		var code string
		select {
		case <-ctx.Done():
			return codexAuthExchangedMsg{Err: ctx.Err(), Gen: gen}
		case err, ok := <-errChan:
			if !ok || err == nil {
				return codexAuthExchangedMsg{Err: errors.New("callback server closed"), Gen: gen}
			}
			return codexAuthExchangedMsg{Err: err, Gen: gen}
		case c, ok := <-codeChan:
			if !ok || c == "" {
				return codexAuthExchangedMsg{Err: errors.New("callback server closed"), Gen: gen}
			}
			code = c
		case manualInput, ok := <-manualChan:
			if !ok || manualInput == "" {
				return codexAuthExchangedMsg{Err: errors.New("manual input closed"), Gen: gen}
			}
			parsedCode, parsedState := config.ParseAuthorizationInput(manualInput)
			if parsedState != "" && parsedState != state {
				return codexAuthExchangedMsg{Err: errors.New("oauth state mismatch"), Gen: gen}
			}
			if parsedCode == "" {
				return codexAuthExchangedMsg{Err: errors.New("missing authorization code"), Gen: gen}
			}
			code = parsedCode
		}

		reqCtx, reqCancel := context.WithTimeout(ctx, 20*time.Second)
		defer reqCancel()

		var cred *config.CodexCredential
		var err error

		if m.ExchangeCodeFunc != nil {
			cred, err = m.ExchangeCodeFunc(reqCtx, nil, code, verifier)
		} else {
			client := &http.Client{Timeout: 20 * time.Second}
			cred, err = config.ExchangeCodexCode(reqCtx, client, code, verifier)
		}

		if err != nil {
			return codexAuthExchangedMsg{Err: err, Gen: gen}
		}

		home := config.HomeDir()
		if err := config.SaveCodexAccount(home, *cred); err != nil {
			return codexAuthExchangedMsg{Err: err, Gen: gen}
		}

		var names []string
		if m.Conn != nil {
			names, _ = daemon.Request[[]string](reqCtx, m.Conn, "/models/codex", nil)
		}

		return codexAuthExchangedMsg{Cred: cred, Models: names, Gen: gen}
	}
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
		if settings.IsCodex() && len(m.Accounts) == 0 {
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
	seen := map[string]int{}
	for _, account := range m.Accounts {
		seen[accountLabel(account)]++
	}
	now := time.Now()
	for _, account := range m.Accounts {
		label := accountLabel(account)
		// Accounts can share an email and plan; the account id tells them apart.
		if seen[label] > 1 && account.AccountID != "" {
			label += " · " + account.AccountID[:min(8, len(account.AccountID))]
		}
		items = append(items, PickerItem{
			ID:     "account:" + config.CredentialIdentity(account),
			Label:  label,
			Detail: accountDetail(account, now),
		})
	}
	items = append(items, PickerItem{
		ID:     "add-openai",
		Label:  "add or update openai-compatible provider",
		Detail: "",
	})
	items = append(items, PickerItem{
		ID:     "add-codex",
		Label:  "add chatgpt codex account",
		Detail: "oauth · supports multiple accounts",
	})

	initialSel := "use:" + m.Profiles.Active
	m.ChoosePicker = NewPickerModel("provider for new sessions", items, false, initialSel)
	m.ChoosePicker.SetSize(m.Width, m.Height)
}

func accountLabel(account config.CodexCredential) string {
	label := account.AccountID
	if account.Email != nil && *account.Email != "" {
		label = *account.Email
	}
	if plan := config.CodexPlan(account); plan != "" {
		label += " · " + plan
	}
	return label
}

func accountDetail(account config.CodexCredential, now time.Time) string {
	detail := "chatgpt account"
	if account.Selected {
		detail += " · selected"
	}
	if until := time.UnixMilli(account.LimitedUntil); account.LimitedUntil > 0 && until.After(now) {
		layout := "15:04"
		if y, m, d := until.Date(); y != now.Year() || m != now.Month() || d != now.Day() {
			layout = "Jan 2 15:04"
		}
		detail += " · usage limit until " + until.Format(layout)
	}
	return detail
}

// removalFor maps a chooser row to what removing it would delete.
func (m LoginModel) removalFor(id string) (removal, bool) {
	if name, ok := strings.CutPrefix(id, "use:"); ok {
		if _, saved := m.Profiles.Providers[name]; saved {
			return removal{Kind: "provider", ID: name, Label: name}, true
		}
	}
	if identity, ok := strings.CutPrefix(id, "account:"); ok {
		for _, account := range m.Accounts {
			if config.CredentialIdentity(account) == identity {
				return removal{Kind: "account", ID: identity, Label: accountLabel(account)}, true
			}
		}
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

func (m LoginModel) removeCmd(target removal) tea.Cmd {
	return func() tea.Msg {
		home := config.HomeDir()
		var err error
		if target.Kind == "account" {
			err = config.RemoveCodexAccount(home, target.ID)
		} else {
			err = config.RemoveProvider(home, target.ID)
		}
		if err != nil {
			return storedMsg{Err: err}
		}
		profiles, err := config.LoadProfiles(home)
		if err != nil {
			return storedMsg{Err: err}
		}
		accounts, err := config.LoadCodexAccounts(home)
		return storedMsg{Profiles: profiles, Accounts: accounts, Err: err}
	}
}

func (m LoginModel) selectAccountCmd(identity string) tea.Cmd {
	return func() tea.Msg {
		home := config.HomeDir()
		if err := config.SelectCodexAccount(home, identity); err != nil {
			return storedMsg{Err: err}
		}
		profiles, err := config.LoadProfiles(home)
		if err != nil {
			return storedMsg{Err: err}
		}
		accounts, err := config.LoadCodexAccounts(home)
		return storedMsg{Profiles: profiles, Accounts: accounts, Err: err}
	}
}

func (m *LoginModel) backToChoose() tea.Cmd {
	m.Step = StepChoose
	m.buildChoosePicker()
	return m.ChoosePicker.Init()
}

func (m *LoginModel) startCodexAuth() tea.Cmd {
	m.Kind = "codex"
	m.Name = "codex"
	m.Step = StepCodexAuth
	m.resetInput()
	m.TextInput.Placeholder = ""
	m.TextInput.Focus()
	m.Generation++
	return m.startCodexCmd(m.Generation)
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
	if m.Step == StepSaving {
		return m.saveProviderCmd(m.Name, m.Draft)
	}
	if m.Step == StepChoose {
		return m.ChoosePicker.Init()
	}
	if m.Step == StepCodexAuth {
		return m.startCodexCmd(m.Generation)
	}
	return textinput.Blink
}

func (m LoginModel) fetchCatalogCmd(ext, endpoint string, gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return loginModelsLoadedMsg{
				Note: "could not read the models.dev catalog; enter a model id",
				Gen:  gen,
			}
		}

		path := fmt.Sprintf("/models/%s?endpoint=%s", ext, url.QueryEscape(endpoint))
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
	case codexAuthStartedMsg:
		if msg.Gen != m.Generation || m.Step != StepCodexAuth {
			// Stale started result: close listener and cancel context immediately
			if msg.Close != nil {
				msg.Close()
			}
			if msg.Cancel != nil {
				msg.Cancel()
			}
			return m, nil
		}

		m.CodexClose = msg.Close
		m.CodexCancel = msg.Cancel
		m.CodexVerifier = msg.Verifier
		m.CodexState = msg.State
		m.CodexAuthURL = msg.AuthURL
		m.CodexStatus = "waiting for browser authorization"
		m.CodexManualChan = make(chan string, 1)
		m.TextInput.Focus()

		var cmds []tea.Cmd
		cmds = append(cmds, textinput.Blink)

		if msg.AuthURL != "" {
			cmds = append(cmds, m.openBrowserCmd(msg.AuthURL))
		}

		if msg.CodeChan == nil {
			m.Error = "could not start callback server on port 1455; paste callback url or code manually"
		}

		cmds = append(cmds, m.waitForCodexAuthCmd(msg.Ctx, msg.CodeChan, msg.ErrChan, m.CodexManualChan, msg.Verifier, msg.State, m.Generation))
		return m, tea.Batch(cmds...)

	case loginModelsLoadedMsg:
		if msg.Gen != m.Generation || m.Step != StepModels {
			return m, nil
		}
		m.Catalog = msg.Models
		if m.Catalog == nil {
			m.Catalog = []string{}
		}
		m.CatalogNote = msg.Note
		m.buildModelPicker()
		return m, m.ModelPicker.Init()

	case codexAuthExchangedMsg:
		if msg.Gen != m.Generation || m.Step != StepCodexAuth {
			return m, nil
		}
		m.cancelCodex()
		if msg.Err != nil {
			m.Error = msg.Err.Error()
			return m, nil
		}
		m.Catalog = msg.Models
		if m.Catalog == nil {
			m.Catalog = []string{}
		}
		if len(m.Catalog) == 0 {
			m.CatalogNote = "models.dev has no OpenAI models cached; enter a model id"
		}
		if current, ok := m.Profiles.Providers["codex"]; ok && current.IsCodex() {
			m.Draft.Model = current.Model
		}
		m.Step = StepCodexModels
		m.buildModelPicker()
		return m, m.ModelPicker.Init()

	case storedMsg:
		m.Removing = removal{}
		m.Error = ""
		if msg.Err != nil {
			m.Error = msg.Err.Error()
		} else {
			m.Profiles = msg.Profiles
			m.Accounts = msg.Accounts
		}
		return m, m.backToChoose()

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
			pickerStep := m.Step == StepChoose || m.Step == StepProtocol || m.Step == StepModels || m.Step == StepCodexModels || m.Step == StepRemove
			if !pickerStep || msg.Type == tea.KeyCtrlD {
				m.cancelCodex()
				m.Generation++
				return m, func() tea.Msg { return LoginCancelMsg{} }
			}
		}

	case PickerSelectMsg:
		switch m.Step {
		case StepChoose:
			if msg.ID == "add-openai" {
				m.Name = ""
				m.Kind = "openai"
				m.Draft = config.Settings{Extension: "openai", BaseURL: "https://api.openai.com/v1", Protocol: "responses"}
				m.Step = StepName
				m.resetInput()
				m.TextInput.Placeholder = ""
				m.TextInput.Focus()
				return m, textinput.Blink
			}
			if msg.ID == "add-codex" {
				return m, m.startCodexAuth()
			}
			// Choosing an account selects it; d removes it.
			if identity, ok := strings.CutPrefix(msg.ID, "account:"); ok {
				m.Step = StepSaving
				return m, m.selectAccountCmd(identity)
			}
			if strings.HasPrefix(msg.ID, "use:") {
				name := strings.TrimPrefix(msg.ID, "use:")
				if s, ok := m.Profiles.Providers[name]; ok {
					// A codex provider with no accounts left cannot run; sign in first.
					if s.IsCodex() && len(m.Accounts) == 0 {
						return m, m.startCodexAuth()
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
			m.Catalog = nil
			m.CatalogNote = ""
			m.Step = StepModels
			m.Generation++
			return m, m.fetchCatalogCmd("openai", m.Draft.BaseURL, m.Generation)

		case StepModels, StepCodexModels:
			if msg.ID == "manual" {
				m.Step = StepModel
				m.resetInput()
				m.TextInput.Placeholder = ""
				m.TextInput.Focus()
				return m, textinput.Blink
			}
			if strings.HasPrefix(msg.ID, "model:") {
				modelName := strings.TrimPrefix(msg.ID, "model:")
				m.Draft.Model = modelName
				m.Step = StepSaving
				if m.Kind == "codex" {
					m.Draft.Extension = "codex"
					m.Draft.Protocol = "responses"
				}
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
			m.Step = StepBaseURL
			m.resetInput()
			m.TextInput.SetValue(m.Draft.BaseURL)
			m.TextInput.Focus()
			return m, textinput.Blink
		}
		if m.Step == StepCodexModels {
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

	case StepModels, StepCodexModels:
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

			_, saved := m.Profiles.Providers[name]
			if name == "codex" && !saved {
				m.Kind = "codex"
				m.Step = StepCodexAuth
				m.resetInput()
				m.TextInput.Placeholder = ""
				m.TextInput.Focus()
				m.Generation++
				return m, m.startCodexCmd(m.Generation)
			}

			// If exists in providers, prefill
			if s, ok := m.Profiles.Providers[name]; ok {
				if s.IsCodex() {
					m.Kind = "codex"
					m.Step = StepCodexAuth
					m.resetInput()
					m.TextInput.Placeholder = ""
					m.TextInput.Focus()
					m.Generation++
					return m, m.startCodexCmd(m.Generation)
				}
				m.Draft = s
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
			m.Step = StepProtocol
			m.buildProtocolPicker()
			return m, m.ProtocolPicker.Init()
		}

	case StepCodexAuth:
		if keyMsg, ok := msg.(tea.KeyMsg); ok && keyMsg.Type == tea.KeyEnter {
			val := strings.TrimSpace(m.TextInput.Value())
			if val != "" && m.CodexManualChan != nil {
				m.CodexStatus = "exchanging authorization code…"
				m.Error = ""
				select {
				case m.CodexManualChan <- val:
				default:
				}
				return m, nil
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
			if m.Kind == "codex" {
				m.Draft.Extension = "codex"
				m.Draft.Protocol = "responses"
			}
			return m, m.saveProviderCmd(m.Name, m.Draft)
		}
	}

	var cmd tea.Cmd
	m.TextInput, cmd = m.TextInput.Update(msg)
	return m, cmd
}

func (m LoginModel) View() string {
	var b strings.Builder
	b.WriteString("albedo /login")
	if m.Name != "" {
		b.WriteString("  " + m.Name)
	}
	b.WriteByte('\n')
	location := "model auth extensions · saved in " + config.HomeDir()
	if m.Width > 0 && ansi.StringWidth(location) > m.Width && ansi.StringWidth(config.HomeDir()) <= m.Width {
		location = "model auth extensions · saved in\n" + config.HomeDir()
	}
	b.WriteString(m.Styles.Dim.Render(ansi.Wrap(location, m.Width, "")))
	b.WriteByte('\n')
	if m.Error != "" {
		b.WriteString(m.Styles.Error.Foreground(lipgloss.Color("1")).Render(ansi.Wrap(m.Error, m.Width, "")))
		b.WriteByte('\n')
	}

	switch m.Step {
	case StepChoose:
		b.WriteString(m.ChoosePicker.View())
		b.WriteByte('\n')
		b.WriteString(m.Styles.Dim.Render(ansi.Wrap("enter select · d remove · esc cancel", m.Width, "")))
	case StepProtocol:
		b.WriteString(m.ProtocolPicker.View())
	case StepRemove:
		b.WriteString(m.ConfirmPicker.View())
	case StepModels, StepCodexModels:
		if m.Catalog == nil {
			b.WriteString(m.Styles.Dim.Render("loading models…"))
			break
		}
		if m.CatalogNote != "" {
			b.WriteString(m.Styles.Dim.Render(m.CatalogNote))
			b.WriteByte('\n')
		}
		b.WriteString(m.ModelPicker.View())
	case StepCodexAuth:
		status := m.CodexStatus
		if status == "" {
			status = "starting codex oauth…"
		}
		b.WriteString(status)
		b.WriteByte('\n')
		if m.CodexAuthURL != "" {
			b.WriteString(m.Styles.Dim.Render(ansi.Hardwrap(m.CodexAuthURL, m.Width, true)))
			b.WriteByte('\n')
		}
		b.WriteString("callback url or code: ")
		b.WriteString(m.TextInput.View())
		b.WriteByte('\n')
		b.WriteString(m.Styles.Dim.Render(ansi.Hardwrap("browser callback completes automatically · enter pastes manually · esc cancel", m.Width, true)))
	case StepSaving:
		if m.Removing.Kind != "" {
			b.WriteString(m.Styles.Dim.Render("removing " + m.Removing.Kind + "…"))
			break
		}
		b.WriteString(m.Styles.Dim.Render("saving provider…"))
	default:
		stepLabels := map[LoginStep]string{
			StepName: "provider name", StepBaseURL: "api base url",
			StepAPIKey: "api key", StepModel: "model id",
		}
		b.WriteString(stepLabels[m.Step] + ": ")
		b.WriteString(m.TextInput.View())
		b.WriteByte('\n')
		var hints []string
		if m.Step == StepAPIKey && m.Draft.APIKey != "" {
			hints = append(hints, "enter keeps the saved key")
		}
		if m.Step == StepName && m.Conn != nil {
			hints = append(hints, "use codex for ChatGPT oauth")
		}
		hints = append(hints, "enter continue", "esc cancel")
		b.WriteString(m.Styles.Dim.Render(ansi.Wrap(strings.Join(hints, " · "), m.Width, "")))
	}
	return b.String()
}
