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
	return len(m.accountsFor(provider)) == 0
}

// accountsFor lists the accounts signed in to a provider.
func (m LoginModel) accountsFor(provider string) []daemon.Account {
	return slices.DeleteFunc(slices.Clone(m.Accounts), func(account daemon.Account) bool { return account.Provider != provider })
}

// accountAt resolves a chooser row back to the account it lists.
func (m LoginModel) accountAt(id string) (daemon.Account, bool) {
	index, err := strconv.Atoi(strings.TrimPrefix(id, "account:"))
	if err != nil || index < 0 || index >= len(m.Accounts) {
		return daemon.Account{}, false
	}
	return m.Accounts[index], true
}

// The rules the accounts picker groups its rows under.
const (
	sectionProviders = "providers"
	sectionAccounts  = "accounts"
	sectionSignIn    = "sign in"
	sectionAdd       = "add a provider"
)

// buildChoosePicker lists everything /login can do: the profiles new sessions
// can use, the accounts the daemon holds, the providers it can sign in to, and
// the ones a profile can be set up for by hand. The rules say which is which,
// so enter can mean one thing per section.
func (m *LoginModel) buildChoosePicker() {
	var items []loginItem
	for _, name := range slices.Sorted(maps.Keys(m.Profiles.Providers)) {
		settings := m.Profiles.Providers[name]
		extension := cmp.Or(settings.Extension, "openai")
		item := loginItem{
			ID:      "use:" + name,
			Label:   name,
			Detail:  m.profileDetail(settings, extension),
			section: sectionProviders,
			facts:   m.profileFacts(settings, extension),
			note:    "enter makes this the one new sessions use",
		}
		if name == m.Profiles.Active {
			item.tag = DefaultStyles.Muted.Render("active")
			item.note = "this is the one new sessions use"
		}
		items = append(items, item)
	}
	for index, account := range m.Accounts {
		note := "enter picks the profile this account signs in for"
		if account.Kind == "service" {
			note = "service account for tools; its tokens stay in creds.json"
		}
		items = append(items, loginItem{
			ID:      "account:" + strconv.Itoa(index),
			Label:   account.Label,
			Detail:  accountDetail(account),
			section: sectionAccounts,
			lead:    DefaultStyles.Success.Render("●"),
			facts:   m.accountFacts(account),
			note:    note,
		})
	}
	for _, login := range m.SignIns {
		accounts := m.accountsFor(login.Provider)
		detail := login.Detail
		if len(accounts) > 0 {
			detail = joinDetail(detail, "signed in")
		}
		note := "enter signs in through the daemon; its tokens stay in creds.json"
		if login.Kind == "service" {
			note = "service sign-in for tools; its tokens stay in creds.json"
		}
		items = append(items, loginItem{
			ID: "signin:" + login.Provider, Label: login.Label, Detail: detail, section: sectionSignIn,
			facts: signInFacts(login, accounts),
			note:  note,
		})
	}
	for _, p := range customProviders {
		items = append(items, loginItem{
			ID: p.ID, Label: p.Label, Detail: p.Detail, section: sectionAdd,
			lead:  DefaultStyles.Muted.Render("+"),
			facts: p.facts(),
			note:  "enter creates this provider profile, or updates the one you have",
		})
	}
	m.ChoosePicker = newLoginPick("", items, "use:"+m.Profiles.Active, m.Width, m.Height)
}

// profileDetail is a profile's one-line summary: what it runs and how it
// authenticates.
func (m LoginModel) profileDetail(settings config.Settings, extension string) string {
	detail := cmp.Or(settings.Model, "no model yet") + " · " + extension
	if _, signIn := m.signInFor(extension); signIn && hasKey(settings) {
		return detail + " · API key"
	}
	if m.signedOut(extension) {
		return detail + " · signed out"
	}
	return detail
}

// profileFacts are what a profile's pane says: what it sends, with what, and
// where its credentials stand.
func (m LoginModel) profileFacts(settings config.Settings, extension string) []loginFact {
	// The model and the extension are the pane's subtitle, so the facts start
	// below them.
	facts := []loginFact{{"protocol", cmp.Or(settings.Protocol, "not set")}}
	if settings.AccountID != nil {
		facts = append(facts, loginFact{"account", m.accountLabel(*settings.AccountID)})
	}
	if settings.Project != nil {
		facts = append(facts, loginFact{"project", *settings.Project})
	}
	if settings.Location != nil {
		facts = append(facts, loginFact{"location", *settings.Location})
	}
	if settings.BaseURL != "" {
		facts = append(facts, loginFact{"endpoint", settings.BaseURL})
	}
	switch _, signIn := m.signInFor(extension); {
	case hasKey(settings):
		facts = append(facts, loginFact{"key", "held by the daemon"})
	case !signIn:
		facts = append(facts, loginFact{"key", "not saved"})
	}
	return facts
}

// accountLabel names the account an id belongs to, or reports it is gone.
func (m LoginModel) accountLabel(id string) string {
	if i := slices.IndexFunc(m.Accounts, func(account daemon.Account) bool { return account.ID == id }); i >= 0 {
		return m.Accounts[i].Label
	}
	return "removed"
}

// accountDetail is an account's one-line summary: its provider, whether it is
// for tools rather than sessions, and whatever the daemon says about it.
func accountDetail(account daemon.Account) string {
	parts := []string{account.Provider}
	if account.Kind == "service" {
		parts = append(parts, "service")
	}
	if account.Detail != "" {
		parts = append(parts, account.Detail)
	}
	return strings.Join(parts, " · ")
}

// accountFacts are what an account's pane says: the provider holding it, the
// profiles using it, and, when two accounts share a label, its id.
func (m LoginModel) accountFacts(account daemon.Account) []loginFact {
	facts := []loginFact{
		{"provider", account.Provider},
		{"used by", joinOr(account.SelectedByProfiles, ", ", "no profile yet")},
	}
	if m.sharedAccountLabel(account) {
		facts = append(facts, loginFact{"id", accountIDPrefix(account.ID)})
	}
	return facts
}

// sharedAccountLabel reports whether another account of the same provider
// carries this one's label, so the two rows are told apart by id.
func (m LoginModel) sharedAccountLabel(account daemon.Account) bool {
	return slices.ContainsFunc(m.Accounts, func(other daemon.Account) bool {
		return other.ID != account.ID && other.Provider == account.Provider && other.Label == account.Label
	})
}

// accountIDPrefix is the first 8 characters of an account id: enough to match
// a row against creds.json, short enough to read.
func accountIDPrefix(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// signInFacts are what a sign-in's pane says: which accounts it already holds.
func signInFacts(login daemon.SignIn, accounts []daemon.Account) []loginFact {
	labels := make([]string, len(accounts))
	for i, account := range accounts {
		labels[i] = account.Label
	}
	return []loginFact{
		{"provider", login.Provider},
		{"accounts", joinOr(labels, ", ", "none yet")},
	}
}

// joinDetail adds a word to a description that may be empty.
func joinDetail(detail, word string) string {
	if detail == "" {
		return word
	}
	return detail + " · " + word
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
	m.confirm.ask("remove", target.ID, "remove", detail+". Remove "+target.Kind+" "+target.Label+"?")
	return nil
}

// confirmKey settles a key on the removal question: enter removes, esc keeps
// what is there, and any other key is ignored.
func (m *LoginModel) confirmKey(msg tea.KeyPressMsg) tea.Cmd {
	if m.confirm.key(msg) {
		m.confirm.dismiss()
		m.Step = StepSaving
		return m.removeCmd(m.Removing)
	}
	if m.confirm.asking() {
		return nil
	}
	return m.backToChoose()
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
	if account.Kind == "service" {
		m.Status = fmt.Sprintf("%s is ready for use with tools; ctrl+d removes it", account.Label)
		return nil
	}
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
	items := make([]loginItem, 0, len(names))
	for _, name := range names {
		settings := m.Profiles.Providers[name]
		extension := cmp.Or(settings.Extension, "openai")
		item := loginItem{
			ID:     name,
			Label:  name,
			Detail: m.profileDetail(settings, extension),
			facts:  m.profileFacts(settings, extension),
			note:   "enter signs " + account.Label + " in for this profile",
		}
		if name == m.Profiles.Active {
			item.tag = DefaultStyles.Muted.Render("active")
		}
		items = append(items, item)
	}
	m.ChoosePicker = newLoginPick("Choose the profile for this account", items, m.Profiles.Active, m.Width, m.Height)
	return m.ChoosePicker.Init()
}

func providerProtocol(provider string) string {
	if provider == "claude" || provider == "opencode-go" || provider == "opencode-zen" {
		return "chat_completions"
	}
	return "responses"
}

func (m *LoginModel) backToChoose() tea.Cmd {
	m.Step = StepChoose
	m.buildChoosePicker()
	return m.ChoosePicker.Init()
}

// flowDetail is what a sign-in flow asks of you.
func flowDetail(flow string) string {
	switch flow {
	case "browser":
		return "opens the provider's page; the daemon finishes it"
	case "manual":
		return "paste the callback URL or code yourself"
	}
	return ""
}

// flowNote says what starting this flow does.
func flowNote(flow string) string {
	if flow == "manual" {
		return "enter starts the sign-in and waits for the code"
	}
	return "enter starts the sign-in and opens the provider's page"
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
		items := make([]loginItem, 0, len(login.Flows))
		for _, flow := range login.Flows {
			items = append(items, loginItem{ID: flow, Label: flow, Detail: flowDetail(flow), note: flowNote(flow)})
		}
		m.ChoosePicker = newLoginPick("Choose a sign-in flow", items, login.Flows[0], m.Width, m.Height)
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
			items := []loginItem{}
			if field.Type == "boolean" {
				items = []loginItem{{ID: "false", Label: "false"}, {ID: "true", Label: "true"}}
			} else {
				for _, choice := range field.Choices {
					items = append(items, loginItem{ID: choice.Label, Label: choice.Label})
				}
			}
			initial := ""
			if index := daemon.FormChoiceDefault(field); index < len(items) {
				initial = items[index].ID
			}
			m.ChoosePicker = newLoginPick(field.Label, items, initial, m.Width, m.Height)
			return m.ChoosePicker.Init()
		}
		initial := ""
		_ = json.Unmarshal(field.Default, &initial)
		// The question already stands on the input line, so the field asks for
		// nothing twice.
		m.TextInput.Placeholder = ""
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

// Startup already read profiles; only authentication choices need loading.
func (m LoginModel) initWithProfiles(profiles config.Profiles) tea.Cmd {
	conn, ctx, gen := m.Conn, m.readCtx, m.Generation
	profiles.Providers = maps.Clone(profiles.Providers)
	return func() tea.Msg {
		listed, err := daemon.SignInList(ctx, conn)
		return signInsLoadedMsg{Listed: listed, Profiles: &profiles, Err: err, Gen: gen}
	}
}
