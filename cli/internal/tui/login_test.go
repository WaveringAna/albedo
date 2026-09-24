package tui

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"

	tea "github.com/charmbracelet/bubbletea"
)

const fakeToken = "fake-daemon-token"

var codexSignIn = daemon.SignIn{
	Provider: "codex",
	Label:    "add chatgpt codex account",
	Detail:   "oauth · supports multiple accounts",
	Protocol: "responses",
}

// fakeDaemon serves the daemon's sign-in routes, so /login runs with no real
// daemon, provider, or browser.
type fakeDaemon struct {
	mu          sync.Mutex
	server      *httptest.Server
	logins      []daemon.SignIn
	accounts    []daemon.Account
	status      daemon.SignInStatus
	models      []string
	listingDown bool
	started     []string
	input       []string
	cancelled   []string
	accountOps  []string
}

func newFakeDaemon(t *testing.T) *fakeDaemon {
	t.Helper()
	f := &fakeDaemon{
		logins: []daemon.SignIn{codexSignIn},
		status: daemon.SignInStatus{State: "waiting", Message: "waiting for browser authorization"},
		models: []string{"gpt-5", "gpt-5-mini"},
	}
	f.server = httptest.NewServer(http.HandlerFunc(f.handle))
	t.Cleanup(f.server.Close)
	return f
}

func (f *fakeDaemon) connection(t *testing.T) *daemon.Connection {
	t.Helper()
	parsed, err := url.Parse(f.server.URL)
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(parsed.Port())
	if err != nil {
		t.Fatal(err)
	}
	return &daemon.Connection{Port: port, Token: fakeToken, Version: 2}
}

func (f *fakeDaemon) setAccounts(accounts ...daemon.Account) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.accounts = accounts
}

func (f *fakeDaemon) setStatus(status daemon.SignInStatus) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.status = status
}

func (f *fakeDaemon) handle(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()

	reply := func(status int, value any) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(value)
	}
	if r.Header.Get("Authorization") != "Bearer "+fakeToken {
		reply(http.StatusForbidden, map[string]string{"error": "forbidden"})
		return
	}

	path := r.URL.Path
	switch {
	case r.Method == http.MethodGet && path == "/auth":
		if f.listingDown {
			reply(http.StatusServiceUnavailable, map[string]string{"error": "sign-in service unavailable"})
			return
		}
		reply(http.StatusOK, daemon.SignIns{Logins: f.logins, Accounts: f.accounts})
	case strings.Contains(path, "/accounts/"):
		f.accountOps = append(f.accountOps, r.Method+" "+r.URL.EscapedPath())
		reply(http.StatusOK, map[string]bool{"ok": true})
	case r.Method == http.MethodPost && strings.HasPrefix(path, "/auth/") && !strings.Contains(path, "/logins/"):
		f.started = append(f.started, strings.TrimPrefix(path, "/auth/"))
		reply(http.StatusCreated, daemon.StartedSignIn{ID: "signin-1", URL: "https://auth.example.test/authorize?state=fixture"})
	case r.Method == http.MethodGet && path == "/auth/logins/signin-1":
		reply(http.StatusOK, f.status)
	case r.Method == http.MethodPost && path == "/auth/logins/signin-1":
		var body struct {
			Input string `json:"input"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.input = append(f.input, body.Input)
		reply(http.StatusOK, map[string]bool{"ok": true})
	case r.Method == http.MethodDelete && path == "/auth/logins/signin-1":
		f.cancelled = append(f.cancelled, "signin-1")
		reply(http.StatusOK, map[string]bool{"ok": true})
	case r.Method == http.MethodGet && strings.HasPrefix(path, "/models/"):
		reply(http.StatusOK, f.models)
	default:
		reply(http.StatusNotFound, map[string]string{"error": "unhandled fake route " + r.Method + " " + path})
	}
}

// newLogin builds a sized /login model with its sign-ins already loaded.
func newLogin(t *testing.T, f *fakeDaemon, hint string) LoginModel {
	t.Helper()
	m := NewLoginModel(f.connection(t), hint)
	m.SetSize(200, 40)
	m, _ = apply(t, m, m.Init())
	return m
}

// apply runs one command tree and feeds everything it produces to the model,
// stopping one level deep so a scheduled poll does not recurse.
func apply(t *testing.T, m LoginModel, cmd tea.Cmd) (LoginModel, tea.Cmd) {
	t.Helper()
	if cmd == nil {
		return m, nil
	}
	msg := cmd()
	if batch, ok := msg.(tea.BatchMsg); ok {
		var next tea.Cmd
		for _, sub := range batch {
			var produced tea.Cmd
			m, produced = apply(t, m, sub)
			if produced != nil {
				next = produced
			}
		}
		return m, next
	}
	m, next := m.Update(msg)
	return m, next
}

func saveOpenAI(t *testing.T, name string) {
	t.Helper()
	settings := config.Settings{BaseURL: "https://api.openai.com/v1", APIKey: "k", Model: "gpt-5", Protocol: "responses"}
	if err := config.SaveProvider(config.HomeDir(), name, settings); err != nil {
		t.Fatal(err)
	}
}

func startSignIn(t *testing.T, m LoginModel, f *fakeDaemon) LoginModel {
	t.Helper()
	m, cmd := m.Update(PickerSelectMsg{ID: "signin:codex"})
	m, _ = apply(t, m, cmd)
	if m.Step != StepOAuth || m.LoginID != "signin-1" {
		t.Fatalf("expected a running sign-in, step=%v id=%q error=%q", m.Step, m.LoginID, m.Error)
	}
	if len(f.started) == 0 || f.started[len(f.started)-1] != "codex" {
		t.Fatalf("expected a codex sign-in start, got %v", f.started)
	}
	return m
}

func pickerIndex(t *testing.T, m LoginModel, id string) int {
	t.Helper()
	for i, item := range m.ChoosePicker.Filtered {
		if item.ID == id {
			return i
		}
	}
	t.Fatalf("no picker row %q in %+v", id, m.ChoosePicker.Items)
	return -1
}

func TestLoginChooserListsDaemonSignInsAndAccounts(t *testing.T) {
	f := newFakeDaemon(t)
	home := t.TempDir()
	t.Setenv("ALBEDO_HOME", home)
	saveOpenAI(t, "local")
	f.setAccounts(daemon.Account{
		Provider: "codex",
		ID:       "account-user:user-1",
		Label:    "a@b.c · plus",
		Detail:   "chatgpt account · selected",
		Selected: true,
	})
	m := newLogin(t, f, "")

	if m.Step != StepChoose {
		t.Fatalf("a saved provider should open the chooser, step=%v error=%q", m.Step, m.Error)
	}
	view := m.View()
	for _, want := range []string{
		"add chatgpt codex account",
		"oauth · supports multiple accounts",
		"a@b.c · plus",
		"chatgpt account · selected",
		"add or update openai-compatible provider",
	} {
		if !strings.Contains(view, want) {
			t.Fatalf("chooser should show %q:\n%s", want, view)
		}
	}
}

func TestLoginSignsInThroughTheDaemon(t *testing.T) {
	home := t.TempDir()
	t.Setenv("ALBEDO_HOME", home)
	f := newFakeDaemon(t)
	m := newLogin(t, f, "")
	var opened []string
	m.BrowserOpener = func(url string) { opened = append(opened, url) }

	if m.Step != StepName {
		t.Fatalf("a fresh install should ask for a provider name, step=%v", m.Step)
	}
	if !strings.Contains(m.View(), "use codex to sign in") {
		t.Fatalf("the name step should offer the daemon's sign-in:\n%s", m.View())
	}

	m.TextInput.SetValue("codex")
	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m, cmd = apply(t, m, cmd)
	if m.Step != StepOAuth || m.LoginID != "signin-1" {
		t.Fatalf("typing a sign-in provider should start it, step=%v error=%q", m.Step, m.Error)
	}
	m, cmd = apply(t, m, cmd)
	if len(opened) != 1 || opened[0] != "https://auth.example.test/authorize?state=fixture" {
		t.Fatalf("the returned url should be opened once, got %v", opened)
	}
	if !strings.Contains(m.View(), "waiting for browser authorization") {
		t.Fatalf("the daemon's progress should be the status line:\n%s", m.View())
	}

	// The waiting status schedules the next poll.
	m, cmd = apply(t, m, cmd)
	if cmd == nil {
		t.Fatal("a waiting sign-in should poll again")
	}

	f.setStatus(daemon.SignInStatus{State: "exchanging", Message: "exchanging authorization code"})
	m, _ = apply(t, m, m.pollSignInCmd(m.LoginID, m.Generation))
	if !strings.Contains(m.View(), "exchanging authorization code") {
		t.Fatalf("the exchanging progress should be the status line:\n%s", m.View())
	}

	f.setStatus(daemon.SignInStatus{State: "done", Message: "a@b.c · plus"})
	m, cmd = apply(t, m, m.pollSignInCmd(m.LoginID, m.Generation))
	if m.Step != StepOAuthModels {
		t.Fatalf("a finished sign-in should list models, step=%v error=%q", m.Step, m.Error)
	}
	if m.LoginID != "" {
		t.Fatalf("a finished sign-in should be forgotten, id=%q", m.LoginID)
	}
	m, _ = apply(t, m, cmd)
	if len(m.Catalog) != 2 || !strings.Contains(m.View(), "gpt-5-mini") {
		t.Fatalf("expected the daemon's models, got %v:\n%s", m.Catalog, m.View())
	}

	m, cmd = m.Update(PickerSelectMsg{ID: "model:gpt-5-mini"})
	saved := cmd()
	if added, ok := saved.(providerSavedMsg); !ok || added.Err != nil {
		t.Fatalf("saving the profile failed: %+v", saved)
	}
	_, doneCmd := m.Update(saved)
	done, ok := doneCmd().(LoginDoneMsg)
	if !ok || done.Name != "codex" {
		t.Fatalf("expected a finished codex login, got %+v", doneCmd())
	}
	want := config.Settings{Extension: "codex", Model: "gpt-5-mini", Protocol: "responses"}
	if done.Settings != want {
		t.Fatalf("saved %+v, want %+v", done.Settings, want)
	}
	profiles, err := config.LoadProfiles(home)
	if err != nil {
		t.Fatal(err)
	}
	if profiles.Providers["codex"] != want {
		t.Fatalf("config.json holds %+v, want %+v", profiles.Providers["codex"], want)
	}
	if len(f.cancelled) != 0 {
		t.Fatalf("a finished sign-in is not cancelled, got %v", f.cancelled)
	}
}

func TestLoginPastesInputAndShowsTheDaemonFailure(t *testing.T) {
	home := t.TempDir()
	t.Setenv("ALBEDO_HOME", home)
	f := newFakeDaemon(t)
	saveOpenAI(t, "local")
	m := newLogin(t, f, "")
	m = startSignIn(t, m, f)
	if len(f.started) != 1 {
		t.Fatalf("expected one codex sign-in start, got %v", f.started)
	}

	f.setStatus(daemon.SignInStatus{State: "failed", Message: "missing authorization code"})
	m.TextInput.SetValue("code#state")
	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m, cmd = apply(t, m, cmd)
	m, _ = apply(t, m, cmd)
	if len(f.input) != 1 || f.input[0] != "code#state" {
		t.Fatalf("the pasted input should reach the daemon, got %v", f.input)
	}
	if m.Error != "missing authorization code" {
		t.Fatalf("a failed sign-in should show the daemon's reason, got %q", m.Error)
	}
	if !strings.Contains(m.View(), "missing authorization code") {
		t.Fatalf("the failure should be visible:\n%s", m.View())
	}
	if m.LoginID != "" {
		t.Fatalf("a failed sign-in should be forgotten, id=%q", m.LoginID)
	}
}

func TestLoginCancelsSignInOnExitAndStaleResults(t *testing.T) {
	home := t.TempDir()
	t.Setenv("ALBEDO_HOME", home)
	f := newFakeDaemon(t)
	saveOpenAI(t, "local")

	m := newLogin(t, f, "")
	m = startSignIn(t, m, f)

	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if m.LoginID != "" || m.Step != StepOAuth {
		t.Fatalf("esc should end the sign-in, step=%v id=%q", m.Step, m.LoginID)
	}
	m, _ = apply(t, m, cmd)
	if len(f.cancelled) != 1 {
		t.Fatalf("esc should cancel the sign-in, got %v", f.cancelled)
	}

	// A result for a generation the client dropped cancels that sign-in.
	running := startSignIn(t, newLogin(t, f, ""), f)
	stale := running.Generation
	running.Generation++
	var dropped tea.Cmd
	running, dropped = apply(t, running, running.pollSignInCmd("signin-1", stale))
	_, _ = apply(t, running, dropped)
	if len(f.cancelled) != 2 {
		t.Fatalf("a dropped generation should cancel its sign-in, got %v", f.cancelled)
	}

	// Leaving the screen cancels whatever is still running.
	running = startSignIn(t, newLogin(t, f, ""), f)
	var closing tea.Cmd
	running, closing = apply(t, running, running.Close())
	_, _ = apply(t, running, closing)
	if len(f.cancelled) != 3 || running.LoginID != "" {
		t.Fatalf("closing the screen should cancel the sign-in, got %v", f.cancelled)
	}
}

func TestLoginSignedOutProviderStartsItsSignIn(t *testing.T) {
	home := t.TempDir()
	t.Setenv("ALBEDO_HOME", home)
	f := newFakeDaemon(t)
	if err := config.SaveProvider(home, "codex", config.Settings{Extension: "codex", Model: "gpt-5", Protocol: "responses"}); err != nil {
		t.Fatal(err)
	}
	m := newLogin(t, f, "")

	if !strings.Contains(m.View(), "gpt-5 · codex · signed out") {
		t.Fatalf("a sign-in provider with no accounts should read signed out:\n%s", m.View())
	}
	m, cmd := m.Update(PickerSelectMsg{ID: "use:codex"})
	m, _ = apply(t, m, cmd)
	if len(f.started) != 1 || f.started[0] != "codex" {
		t.Fatalf("choosing a signed-out provider should sign in, got %v", f.started)
	}
	if m.Step != StepOAuth {
		t.Fatalf("expected the sign-in step, got %v", m.Step)
	}
}

func TestLoginSelectsAndRemovesAccountsThroughTheDaemon(t *testing.T) {
	home := t.TempDir()
	t.Setenv("ALBEDO_HOME", home)
	f := newFakeDaemon(t)
	if err := config.SaveProvider(home, "codex", config.Settings{Extension: "codex", Model: "gpt-5", Protocol: "responses"}); err != nil {
		t.Fatal(err)
	}
	f.setAccounts(
		daemon.Account{Provider: "codex", ID: "account-user:user-1", Label: "a@b.c · plus", Detail: "chatgpt account"},
		daemon.Account{Provider: "codex", ID: "account:acct/2", Label: "c@d.e", Detail: "chatgpt account · selected"},
	)
	m := newLogin(t, f, "")
	if strings.Contains(m.View(), "signed out") {
		t.Fatalf("codex has accounts and should not read signed out:\n%s", m.View())
	}

	m, cmd := m.Update(PickerSelectMsg{ID: "account:0"})
	m, _ = apply(t, m, cmd)
	if m.Step != StepChoose || m.Error != "" {
		t.Fatalf("selecting an account should return to the chooser, step=%v error=%q", m.Step, m.Error)
	}
	if len(f.accountOps) != 1 || f.accountOps[0] != "POST /auth/codex/accounts/account-user:user-1" {
		t.Fatalf("selecting should post to the account, got %v", f.accountOps)
	}

	m.ChoosePicker.Cursor = pickerIndex(t, m, "account:1")
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("d")})
	if m.Step != StepRemove || m.Removing.ID != "account:acct/2" || m.Removing.Provider != "codex" {
		t.Fatalf("d on an account should confirm its removal, step=%v removing=%+v", m.Step, m.Removing)
	}
	m, cmd = m.Update(PickerSelectMsg{ID: "remove"})
	m, _ = apply(t, m, cmd)
	if m.Step != StepChoose || m.Error != "" {
		t.Fatalf("expected the chooser after removal, step=%v error=%q", m.Step, m.Error)
	}
	if len(f.accountOps) != 2 || !strings.Contains(f.accountOps[1], "DELETE /auth/codex/accounts/account:acct%2F2") {
		t.Fatalf("removing should delete the escaped account path, got %v", f.accountOps)
	}
}

func TestLoginRemovesHighlightedProvider(t *testing.T) {
	f := newFakeDaemon(t)
	home := t.TempDir()
	t.Setenv("ALBEDO_HOME", home)
	for _, name := range []string{"local", "work"} {
		saveOpenAI(t, name)
	}
	m := newLogin(t, f, "")

	if item, _ := m.ChoosePicker.Highlighted(); item.ID != "use:work" {
		t.Fatalf("expected the active provider highlighted, got %q", item.ID)
	}
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("d")})
	if m.Step != StepRemove || m.Removing.Kind != "provider" || m.Removing.ID != "work" {
		t.Fatalf("d should confirm removing the highlighted provider, got step=%v removing=%+v", m.Step, m.Removing)
	}
	m, _ = m.Update(PickerCancelMsg{})
	if m.Step != StepChoose {
		t.Fatalf("cancelling the confirmation should return to the chooser, step=%v", m.Step)
	}

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyDelete})
	m, cmd := m.Update(PickerSelectMsg{ID: "remove"})
	m, _ = apply(t, m, cmd)
	if _, ok := m.Profiles.Providers["work"]; ok || m.Profiles.Active != "local" {
		t.Fatalf("expected work removed and local active, got %+v", m.Profiles)
	}
	if strings.Contains(m.View(), "work") {
		t.Fatalf("removed provider is still listed:\n%s", m.View())
	}
}

func TestLoginReportsAnUnavailableSignInService(t *testing.T) {
	home := t.TempDir()
	t.Setenv("ALBEDO_HOME", home)
	f := newFakeDaemon(t)
	f.listingDown = true
	saveOpenAI(t, "local")
	m := newLogin(t, f, "")

	if m.Step != StepChoose || !strings.Contains(m.Error, "sign-in service unavailable") {
		t.Fatalf("expected the daemon's error, step=%v error=%q", m.Step, m.Error)
	}
	if !strings.Contains(m.View(), "use:local") && !strings.Contains(m.View(), "local") {
		t.Fatalf("saved providers should still be choosable:\n%s", m.View())
	}
}
