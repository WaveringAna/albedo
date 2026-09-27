// The manual openai-compatible provider wizard crosses the composer, the
// daemon's sign-in and model-catalog answers, and config.json on disk. A
// stubbed daemon cannot prove the real answers lead the wizard to that save.
package e2e

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"albedo/cli/internal/config"
	"albedo/cli/internal/tui"

	tea "charm.land/bubbletea/v2"
)

func TestTUILoginAddsAManualProviderThroughTheDaemon(t *testing.T) {
	name, key, model := "wanderer", "sk-wanderer-fixture", "hermit-mini"
	providerRoute(t, echoReply)
	// The wizard reads and writes config.json in process; pointing it at the
	// suite home puts the saved profile where the daemon reads it back.
	t.Setenv("ALBEDO_HOME", suite.home)
	// The saved provider would change the next run's /login, so it is undone.
	configPath := filepath.Join(suite.home, "config.json")
	saved, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.WriteFile(configPath, saved, 0o600) })
	before, err := config.LoadProfiles(suite.home)
	if err != nil {
		t.Fatalf("suite config: %v", err)
	}
	baseURL := before.Providers[t.Name()].BaseURL
	d := newTUIDriver(t)
	// expect fails unless the wizard is asking this question next.
	expect := func(want tui.LoginStep) {
		t.Helper()
		if d.App.Login.Step != want {
			t.Fatalf("the wizard is on step %v, want %v", d.App.Login.Step, want)
		}
	}

	d.App.Chat.TextArea.SetValue("/login " + name)
	opened, ok := d.Key(tea.KeyEnter).(tui.ChatOpenLoginMsg)
	if !ok || opened.Name != name {
		t.Fatalf("enter did not open /login: %#v", opened)
	}
	// Login.Init asks the daemon what can be signed in to; only its answer
	// applies the hint, which lands on the wizard's base-url question.
	d.Dispatch(opened)
	if d.App.State != tui.AppStateLogin || !strings.Contains(d.View(), "api base url") {
		t.Fatalf("the daemon's sign-in answer did not route the hint: state=%v\n%s", d.App.State, d.View())
	}
	expect(tui.StepBaseURL)

	d.App.Login.TextInput.SetValue(baseURL)
	d.Key(tea.KeyEnter)
	expect(tui.StepAPIKey)
	d.App.Login.TextInput.SetValue(key)
	d.Key(tea.KeyEnter)
	expect(tui.StepProtocol)

	// The keyboard alone moves the protocol picker off the default responses.
	d.Key(tea.KeyDown)
	picked, ok := d.Key(tea.KeyEnter).(tui.PickerSelectMsg)
	if !ok || picked.ID != "chat_completions" {
		t.Fatalf("enter did not pick the protocol: %#v", picked)
	}
	// The catalog question goes through the real daemon, which finds no
	// models.dev cache and answers with an empty list.
	d.Dispatch(picked)
	if len(d.App.Login.Catalog) != 0 || !strings.Contains(d.App.Login.CatalogNote, "no matching models") || !strings.Contains(d.View(), "enter a model id") {
		t.Fatalf("the daemon's empty catalog did not reach the model step: catalog=%v note=%q\n%s", d.App.Login.Catalog, d.App.Login.CatalogNote, d.View())
	}
	manual, ok := d.Key(tea.KeyEnter).(tui.PickerSelectMsg)
	if !ok || manual.ID != "manual" {
		t.Fatalf("an empty catalog leaves only manual entry: %#v", manual)
	}
	d.Dispatch(manual)
	expect(tui.StepModel)

	d.App.Login.TextInput.SetValue(model)
	// The save lands in config.json; the app reloads it and returns to chat.
	d.Dispatch(d.Key(tea.KeyEnter))
	if d.App.State != tui.AppStateChat || !strings.Contains(d.View(), "› ") || d.App.Profiles.Active != name {
		t.Fatalf("the app did not return to chat with %q active: state=%v active=%q\n%s", name, d.App.State, d.App.Profiles.Active, d.View())
	}

	profiles, err := config.LoadProfiles(suite.home)
	if err != nil {
		t.Fatalf("saved config: %v", err)
	}
	got := profiles.Providers[name]
	want := config.Settings{Extension: "openai", BaseURL: baseURL, APIKey: key, Model: model, Protocol: "chat_completions"}
	if got != want {
		t.Fatalf("config.json kept %+v, want %+v", got, want)
	}
	if profiles.Active != name {
		t.Fatalf("config.json kept %q active, not %q", profiles.Active, name)
	}
}
