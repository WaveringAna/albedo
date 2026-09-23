package tui

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/config"

	tea "github.com/charmbracelet/bubbletea"
)

func codexTestCredential(accountID, email string) config.CodexCredential {
	return config.CodexCredential{
		Type:      "oauth",
		Access:    "access-" + accountID,
		Refresh:   "refresh-" + accountID,
		Expires:   1 << 50,
		AccountID: accountID,
		Email:     &email,
	}
}

func TestLoginListsAndRemovesCodexAccounts(t *testing.T) {
	home := t.TempDir()
	t.Setenv("ALBEDO_HOME", home)
	if err := config.SaveProvider(home, "codex", config.Settings{Extension: "codex", Model: "gpt-5", Protocol: "responses"}); err != nil {
		t.Fatal(err)
	}
	gone := codexTestCredential("acct-1", "gone@example.test")
	kept := codexTestCredential("acct-2", "kept@example.test")
	for _, c := range []config.CodexCredential{gone, kept} {
		if err := config.SaveCodexAccount(home, c); err != nil {
			t.Fatal(err)
		}
	}

	m := NewLoginModel(nil, "")
	view := m.View()
	for _, want := range []string{"gone@example.test", "kept@example.test"} {
		if !strings.Contains(view, want) {
			t.Fatalf("login should list %s:\n%s", want, view)
		}
	}
	if strings.Contains(view, "signed out") {
		t.Fatalf("codex has accounts and should not read signed out:\n%s", view)
	}

	m.ChoosePicker.Cursor = pickerIndex(t, m, "account:"+config.CredentialIdentity(gone))
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("d")})
	if m.Step != StepRemove {
		t.Fatalf("d on an account should ask to confirm removal, step=%v", m.Step)
	}
	m, cmd := m.Update(PickerSelectMsg{ID: "remove"})
	m, _ = m.Update(cmd())
	if m.Step != StepChoose || m.Error != "" {
		t.Fatalf("expected the chooser after removal, step=%v error=%q", m.Step, m.Error)
	}
	if strings.Contains(m.View(), "gone@example.test") {
		t.Fatalf("removed account is still listed:\n%s", m.View())
	}

	m.ChoosePicker.Cursor = pickerIndex(t, m, "account:"+config.CredentialIdentity(kept))
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("d")})
	m, cmd = m.Update(PickerSelectMsg{ID: "remove"})
	m, _ = m.Update(cmd())
	if !strings.Contains(m.View(), "signed out") {
		t.Fatalf("codex without accounts should read signed out:\n%s", m.View())
	}
	if accounts, _ := config.LoadCodexAccounts(home); len(accounts) != 0 {
		t.Fatalf("expected auth.json to hold no accounts, got %d", len(accounts))
	}

	m, _ = m.Update(PickerSelectMsg{ID: "use:codex"})
	if m.Step != StepCodexAuth {
		t.Fatalf("choosing a signed-out codex provider should start sign-in, step=%v", m.Step)
	}
	m.cancelCodex()
}

func TestLoginRemovesHighlightedProvider(t *testing.T) {
	home := t.TempDir()
	t.Setenv("ALBEDO_HOME", home)
	for _, name := range []string{"local", "work"} {
		if err := config.SaveProvider(home, name, config.Settings{BaseURL: "https://api.openai.com/v1", APIKey: "k", Model: "gpt-5", Protocol: "responses"}); err != nil {
			t.Fatal(err)
		}
	}

	m := NewLoginModel(nil, "")
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
	m, _ = m.Update(cmd())
	if _, ok := m.Profiles.Providers["work"]; ok || m.Profiles.Active != "local" {
		t.Fatalf("expected work removed and local active, got %+v", m.Profiles)
	}
	if strings.Contains(m.View(), "work") {
		t.Fatalf("removed provider is still listed:\n%s", m.View())
	}
}

func pickerIndex(t *testing.T, m LoginModel, id string) int {
	t.Helper()
	for i, item := range m.ChoosePicker.Filtered {
		if item.ID == id {
			return i
		}
	}
	t.Fatalf("no picker row %q", id)
	return -1
}

func planToken(plan string) string {
	payload, _ := json.Marshal(map[string]any{"https://api.openai.com/auth": map[string]string{"chatgpt_plan_type": plan}})
	return "h." + base64.RawURLEncoding.EncodeToString(payload) + ".s"
}

func TestLoginTellsApartAndSelectsAccountsSharingAnEmail(t *testing.T) {
	home := t.TempDir()
	t.Setenv("ALBEDO_HOME", home)
	work := codexTestCredential("acct-work", "same@example.test")
	work.Access = planToken("team")
	work.LimitedUntil = time.Now().Add(time.Hour).UnixMilli()
	personal := codexTestCredential("acct-home", "same@example.test")
	personal.Access = planToken("plus")
	twin := codexTestCredential("acct-twin", "same@example.test")
	twin.Access = planToken("plus")
	for _, c := range []config.CodexCredential{work, personal, twin} {
		if err := config.SaveCodexAccount(home, c); err != nil {
			t.Fatal(err)
		}
	}

	m := NewLoginModel(nil, "")
	m.SetSize(200, 40)
	view := m.View()
	for _, want := range []string{"same@example.test · team", "usage limit until", "same@example.test · plus · acct-hom", "same@example.test · plus · acct-twi"} {
		if !strings.Contains(view, want) {
			t.Fatalf("login should show %q:\n%s", want, view)
		}
	}

	m, cmd := m.Update(PickerSelectMsg{ID: "account:" + config.CredentialIdentity(personal)})
	m, _ = m.Update(cmd())
	if m.Step != StepChoose || m.Error != "" {
		t.Fatalf("expected the chooser after selecting, step=%v error=%q", m.Step, m.Error)
	}
	accounts, err := config.LoadCodexAccounts(home)
	if err != nil {
		t.Fatal(err)
	}
	for _, account := range accounts {
		if want := account.AccountID == "acct-home"; account.Selected != want {
			t.Fatalf("account %s selected=%v, want %v", account.AccountID, account.Selected, want)
		}
		if account.AccountID == "acct-work" && account.LimitedUntil != work.LimitedUntil {
			t.Fatalf("selecting must keep the recorded usage limit")
		}
	}
	if !strings.Contains(m.View(), "selected") {
		t.Fatalf("the chosen account should read selected:\n%s", m.View())
	}
}
