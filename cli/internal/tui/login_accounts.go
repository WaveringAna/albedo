package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"encoding/json"
	"fmt"
	"maps"
	"slices"
	"strconv"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
)

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
	detail := "This removes the provider and its saved key"
	if target.Kind == "account" {
		detail = "This removes its saved tokens"
	}
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
			return signInsLoadedMsg{Mutation: true, Err: err, Gen: m.Generation}
		}
		result := m.listSignIns(m.readCtx, m.Generation)
		result.Mutation = true
		return result
	}
}

func (m LoginModel) removeCmd(target removal) tea.Cmd {
	return m.reloadCmd(func(ctx context.Context) error {
		if target.Kind == "account" {
			return daemon.RemoveAccount(ctx, m.Conn, target.ID)
		}
		return daemon.DeleteProvider(ctx, m.Conn, target.ID, m.Profiles)
	})
}

func (m LoginModel) selectAccountCmd(account daemon.Account) tea.Cmd {
	return m.reloadCmd(func(ctx context.Context) error {
		return daemon.SelectProfileAccount(ctx, m.Conn, m.Name, account, m.Profiles)
	})
}

func (m *LoginModel) chooseAccount(account daemon.Account) tea.Cmd {
	var names []string
	for name, profile := range m.Profiles.Providers {
		if profile.Extension == account.Provider {
			names = append(names, name)
		}
	}
	slices.Sort(names)
	if len(names) == 0 {
		m.Name = account.Provider
		m.Draft = config.Settings{Extension: account.Provider, Protocol: providerProtocol(account.Provider), AccountID: &account.ID}
		m.Step = StepOAuthModels
		return m.fetchCatalogCmd(account.Provider, "", m.Generation)
	}
	if len(names) == 1 {
		m.Name = names[0]
		m.Step = StepSaving
		return m.selectAccountCmd(account)
	}
	m.SelectedAccount = &account
	m.Step = StepAccountProfile
	items := make([]PickerItem, 0, len(names))
	for _, name := range names {
		items = append(items, PickerItem{ID: name, Label: name, Detail: "use " + account.Label})
	}
	m.ChoosePicker = NewPickerModel("Choose the profile for this account", items, false, m.Profiles.Active)
	m.ChoosePicker.SetSize(m.Width, m.Height)
	return m.ChoosePicker.Init()
}

func providerProtocol(provider string) string {
	if provider == "claude" {
		return "chat_completions"
	}
	return "responses"
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
	m.Draft = config.Settings{Extension: login.Provider, Protocol: providerProtocol(login.Provider)}
	if saved, ok := m.Profiles.Providers[login.Provider]; ok {
		m.Draft = saved
	}
	m.Generation = nextPageGeneration()
	m.LoginFields = slices.Clone(login.Fields)
	m.LoginValues = map[string]json.RawMessage{}
	m.LoginFieldIndex = 0
	m.LoginFlow = ""
	m.LoginInstructions = ""
	m.LoginID = ""
	m.LoginETag = ""
	m.SignInURL = ""
	m.Error = ""
	if len(login.Flows) > 1 {
		m.Step = StepOAuthFlow
		items := make([]PickerItem, 0, len(login.Flows))
		for _, flow := range login.Flows {
			items = append(items, PickerItem{ID: flow, Label: flow})
		}
		m.ChoosePicker = NewPickerModel("Choose a sign-in flow", items, false, login.Flows[0])
		m.ChoosePicker.SetSize(m.Width, m.Height)
		return m.ChoosePicker.Init()
	}
	if len(login.Flows) == 1 {
		m.LoginFlow = login.Flows[0]
	}
	return m.nextLoginField()
}

func (m *LoginModel) nextLoginField() tea.Cmd {
	for m.LoginFieldIndex < len(m.LoginFields) {
		field := m.LoginFields[m.LoginFieldIndex]
		if field.Type == "hidden" {
			m.LoginValues[field.Name] = slices.Clone(field.Default)
			m.LoginFieldIndex++
			continue
		}
		m.Step = StepOAuthFields
		if field.Type == "choice" || field.Type == "boolean" {
			items := []PickerItem{}
			if field.Type == "boolean" {
				items = []PickerItem{{ID: "false", Label: "false"}, {ID: "true", Label: "true"}}
			} else {
				for _, choice := range field.Choices {
					items = append(items, PickerItem{ID: choice.Label, Label: choice.Label})
				}
			}
			initial := ""
			if index := daemon.FormChoiceDefault(field); index < len(items) {
				initial = items[index].ID
			}
			m.ChoosePicker = NewPickerModel(field.Label, items, false, initial)
			m.ChoosePicker.SetSize(m.Width, m.Height)
			return m.ChoosePicker.Init()
		}
		initial := ""
		_ = json.Unmarshal(field.Default, &initial)
		m.TextInput.Placeholder = field.Label
		return m.promptInput(initial, field.Type == "secret")
	}
	return m.beginLoginCmd()
}

func (m *LoginModel) beginLoginCmd() tea.Cmd {
	m.Step = StepOAuth
	m.Status = "starting sign-in…"
	m.TextInput.Placeholder = ""
	m.promptInput("", false)
	conn, provider, flow, gen, lifetime := m.Conn, m.Provider, m.LoginFlow, m.Generation, m.readCtx
	values := maps.Clone(m.LoginValues)
	m.LoginValues = nil
	m.LoginFields = nil
	return func() tea.Msg {
		started, err := daemon.StartProviderLogin(context.Background(), conn, provider, flow, values)
		// Cleanup also runs if the program has already stopped receiving messages.
		if lifetime.Err() != nil && started.ID != "" {
			if cleanupErr := daemon.CancelSignIn(context.Background(), conn, started.ID); cleanupErr == nil {
				return signInStartedMsg{Err: lifetime.Err(), Gen: gen}
			}
		}
		return signInStartedMsg{ID: started.ID, URL: started.URL, ETag: started.ETag, Err: err, Gen: gen}
	}
}

func (m *LoginModel) acceptLoginField(text string) tea.Cmd {
	field := m.LoginFields[m.LoginFieldIndex]
	value, err := daemon.ParseActionField(field, text)
	if err != nil {
		m.Error = err.Error()
		return nil
	}
	if value != nil {
		m.LoginValues[field.Name] = value
	}
	m.LoginFieldIndex++
	m.Error = ""
	m.TextInput.SetValue("")
	return m.nextLoginField()
}

func (m LoginModel) pollSignInCmd(id string, gen int) tea.Cmd {
	return func() tea.Msg {
		status, err := daemon.PollSignIn(m.readCtx, m.Conn, id)
		return signInStatusMsg{ID: id, State: status.State, Message: status.Message, ETag: status.ETag, Instructions: status.Instructions, Accounts: status.Accounts, URL: status.URL, Err: err, Gen: gen}
	}
}

func signInPollTickCmd(id string, gen int) tea.Cmd {
	return tea.Tick(signInPollInterval, func(time.Time) tea.Msg {
		return signInPollMsg{ID: id, Gen: gen}
	})
}

func (m LoginModel) inputSignInCmd(id, input string, gen int) tea.Cmd {
	return func() tea.Msg {
		if err := daemon.SignInInput(context.Background(), m.Conn, id, input, m.LoginETag); err != nil {
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
	if m.cancelReads != nil {
		m.cancelReads()
	}
	m.closed = true
	m.Generation = nextPageGeneration()
	m.LoginValues = nil
	m.LoginFields = nil
	m.TextInput.SetValue("")
	m.Draft.APIKey = ""
	return m.endSignIn()
}

// listSignIns reads what the daemon can sign in with, the accounts it holds,
// and which profiles it holds an api key for.
func (m LoginModel) listSignIns(ctx context.Context, gen int) signInsLoadedMsg {
	listed, err := daemon.SignInList(ctx, m.Conn)
	if err != nil {
		return signInsLoadedMsg{Err: err, Gen: gen}
	}
	settings, err := daemon.GetSettings(ctx, m.Conn)
	return signInsLoadedMsg{Listed: listed, Profiles: &settings.Profiles, Err: err, Gen: gen}
}
