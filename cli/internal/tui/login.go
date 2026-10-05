package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
)

type LoginStep int

const (
	StepChoose LoginStep = iota
	StepName
	StepBaseURL
	StepAPIKey
	StepProject
	StepLocation
	StepProtocol
	StepModels
	StepModel
	StepOAuth
	StepOAuthModels
	StepRemove
	StepSaving
	StepAccountProfile
	StepOAuthFlow
	StepOAuthFields
)

// signInPollInterval is how often the daemon is asked about a running sign-in.
const signInPollInterval = 300 * time.Millisecond

// removal names something /login can delete: a provider in config.json or an
// account in the daemon's credential store.
type removal struct {
	Kind     string // "provider" | "account"
	Provider string
	ID       string // provider name or daemon account id
	Label    string
}

type LoginModel struct {
	readCtx                      context.Context
	cancelReads                  context.CancelFunc
	closed                       bool
	Styles                       Styles
	Conn                         *daemon.Connection
	openBrowser                  func(url string)
	Removing                     removal
	Profiles                     config.Profiles
	Hint                         string
	Name                         string
	Provider                     string // sign-in provider in flight, or just finished
	LoginETag                    string
	LoginFlow, LoginInstructions string
	LoginFields                  []daemon.FormField
	LoginFieldIndex              int
	LoginValues                  map[string]json.RawMessage
	SelectedAccount              *daemon.Account
	LoginID                      string // daemon id of the sign-in in flight
	SignInURL                    string
	Status                       string // daemon progress line while a sign-in runs
	CatalogNote                  string
	Error                        string
	Draft                        config.Settings
	SignIns                      []daemon.SignIn
	Accounts                     []daemon.Account
	Catalog                      []string
	TextInput                    textinput.Model
	ChoosePicker                 PickerModel
	ProtocolPicker               PickerModel
	ModelPicker                  PickerModel
	ConfirmPicker                PickerModel
	Generation                   int
	Width                        int
	Height                       int
	Step                         LoginStep
}

// NewLoginModel panics if conn is nil. A nil browser opener disables automatic
// browser launches.
func NewLoginModel(conn *daemon.Connection, nameHint string, openBrowser func(string)) LoginModel {
	if conn == nil {
		panic("tui.NewLoginModel requires a daemon connection")
	}
	profiles := config.Profiles{Providers: map[string]config.Settings{}}

	readCtx, cancelReads := context.WithCancel(context.Background())
	m := LoginModel{
		Generation:  nextPageGeneration(),
		readCtx:     readCtx,
		cancelReads: cancelReads,
		Conn:        conn,
		Step:        StepChoose,
		Profiles:    profiles,
		Hint:        strings.TrimSpace(nameHint),
		Draft:       config.Settings{Extension: "openai", BaseURL: "https://api.openai.com/v1", Protocol: "responses"},
		TextInput:   newField(),
		Styles:      DefaultStyles,
		openBrowser: openBrowser,
	}
	m.buildChoosePicker()
	return m
}

func (m LoginModel) Init() tea.Cmd {
	gen := m.Generation
	return func() tea.Msg { return m.listSignIns(m.readCtx, gen) }
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
			m.TextInput.Placeholder = ""
			return m, m.promptInput("", false)
		}
		return m, m.ChoosePicker.Init()

	case signInStartedMsg:
		if msg.Gen != m.Generation || m.Step != StepOAuth {
			// Stale start: cancel the sign-in this client no longer shows.
			if msg.ID == m.LoginID {
				return m, nil
			}
			return m, m.cancelSignInCmd(msg.ID)
		}
		m.LoginID = msg.ID
		m.LoginETag = msg.ETag
		if msg.Err != nil {
			m.Error = operationError(msg.Err, "", "Sign-in may have started; check your accounts before starting another. Its outcome cannot be confirmed from this response.")
			if msg.ID == "" {
				return m, nil
			}
			return m, signInPollTickCmd(msg.ID, m.Generation)
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
			if msg.ID == m.LoginID {
				return m, nil
			}
			return m, m.cancelSignInCmd(msg.ID)
		}
		return m, m.pollSignInCmd(msg.ID, msg.Gen)

	case signInStatusMsg:
		if msg.Gen != m.Generation || m.Step != StepOAuth || msg.ID != m.LoginID {
			// A stale result: cancel the sign-in this client no longer shows.
			if msg.ID == m.LoginID {
				return m, nil
			}
			return m, m.cancelSignInCmd(msg.ID)
		}
		if msg.Err != nil {
			m.Error = msg.Err.Error()
			if api, ok := errors.AsType[*daemon.APIError](msg.Err); ok && (api.StatusCode == 404 || api.StatusCode == 410) {
				return m, m.endSignIn()
			}
			return m, signInPollTickCmd(msg.ID, m.Generation)
		}
		m.LoginETag = msg.ETag
		m.LoginInstructions = msg.Instructions
		var browser tea.Cmd
		if m.SignInURL == "" && msg.URL != "" {
			m.SignInURL = msg.URL
			browser = m.openBrowserCmd(msg.URL)
		}
		m.Status = msg.Message
		switch msg.State {
		case "complete":
			m.LoginID = ""
			if len(msg.Accounts) > 0 {
				m.Draft.AccountID = &msg.Accounts[0].ID
			}
			m.Step = StepOAuthModels
			m.Generation = nextPageGeneration()
			return m, m.fetchCatalogCmd(m.Provider, "", m.Generation)
		case "failed", "cancelled", "expired":
			m.LoginID = ""
			m.Error = msg.Message
			return m, nil
		default:
			return m, tea.Batch(browser, signInPollTickCmd(msg.ID, m.Generation))
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
		if msg.Gen != m.Generation || m.closed {
			return m, nil
		}
		if msg.Err != nil {
			m.Error = msg.Err.Error()
			if m.Name == msg.Name && m.Draft.Model != "" {
				m.Step = StepModel
				return m, m.promptInput(m.Draft.Model, false)
			}
			return m, m.backToChoose()
		}
		return m, func() tea.Msg {
			return LoginDoneMsg{Gen: msg.Gen, Name: msg.Name, Settings: msg.Settings}
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
			pickerStep := m.Step == StepChoose || m.Step == StepAccountProfile || m.Step == StepOAuthFlow || m.Step == StepProtocol || m.Step == StepModels || m.Step == StepOAuthModels || m.Step == StepRemove
			if !pickerStep || key == "ctrl+d" {
				cancel := m.Close()
				m.LoginValues = nil
				m.LoginFields = nil
				m.TextInput.SetValue("")
				m.Generation = nextPageGeneration()
				return m, tea.Batch(cancel, func() tea.Msg { return LoginCancelMsg{} })
			}
		}

	case PickerSelectMsg:
		switch m.Step {
		case StepOAuthFlow:
			m.LoginFlow = msg.ID
			return m, m.nextLoginField()
		case StepOAuthFields:
			return m, m.acceptLoginField(msg.ID)
		case StepAccountProfile:
			if m.SelectedAccount != nil {
				m.Name = msg.ID
				m.Step = StepSaving
				return m, m.selectAccountCmd(*m.SelectedAccount)
			}
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
				return m, m.chooseAccount(account)
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
		case StepOAuthFlow, StepOAuthFields:
			return m, m.backToChoose()
		case StepChoose, StepOAuthModels:
			return m, func() tea.Msg { return LoginCancelMsg{} }
		case StepProtocol:
			m.Step = StepAPIKey
			return m, m.promptInput("", true)
		case StepModels:
			m.Generation = nextPageGeneration()
			if p, _ := m.custom(); p.Scoped {
				return m, m.askLocation()
			}
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
	if m.Step == StepOAuthFields && m.LoginFieldIndex < len(m.LoginFields) {
		field := m.LoginFields[m.LoginFieldIndex]
		if field.Type == "choice" || field.Type == "boolean" {
			var cmd tea.Cmd
			m.ChoosePicker, cmd = m.ChoosePicker.Update(msg)
			return m, cmd
		}
	}

	switch m.Step {
	case StepChoose, StepAccountProfile, StepOAuthFlow, StepProtocol, StepRemove, StepModels, StepOAuthModels:
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
			endpoint := ""
			if p, _ := m.custom(); val != "" || !p.Optional {
				var err error
				if endpoint, err = config.ValidateEndpoint(val); err != nil {
					return m.fail(err.Error())
				}
			}
			if endpoint != m.Draft.BaseURL {
				m.Draft.APIKey, m.Draft.HasKey = "", false
			}
			m.Draft.BaseURL = endpoint
			m.Error = ""
			return m, m.askAPIKey()

		case StepAPIKey:
			m.TextInput.SetCursor(0)
			switch val := cmp.Or(m.TextInput.Value(), m.Draft.APIKey); {
			case val == "" && m.Draft.HasKey:
				// Blank keeps the key the daemon holds.
			case val == "" && m.optionalKey():
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

		case StepProject:
			m.TextInput.SetCursor(0)
			m.Draft.Project = optionalText(strings.TrimSpace(m.TextInput.Value()))
			m.Error = ""
			return m, m.askLocation()

		case StepLocation:
			m.TextInput.SetCursor(0)
			m.Draft.Location = optionalText(strings.TrimSpace(m.TextInput.Value()))
			m.Error = ""
			return m, m.advanceToModels()

		case StepOAuthFields:
			return m, m.acceptLoginField(m.TextInput.Value())
		case StepOAuth:
			val := strings.TrimSpace(m.TextInput.Value())
			if val != "" && m.LoginID != "" {
				m.Status = "exchanging authorization code…"
				m.Error = ""
				m.Generation = nextPageGeneration()
				m.TextInput.SetValue("")
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
