// Login's lists and removal question are keystroke behaviour the e2e suite
// reaches only through the daemon's flows: a letter typed into the always-live
// search must not remove a provider (the old bare "d" did), removal waits for
// enter, and a text step takes letters as input rather than as actions.
package tui

import (
	"albedo/cli/internal/daemon"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"

	tea "charm.land/bubbletea/v2"
)

func TestLoginRemovalAsksThenTakesEnterOnly(t *testing.T) {
	m := loginModel(120, 30)
	m, _ = m.Update(tea.KeyPressMsg{Code: 'd', Mod: tea.ModCtrl})
	if m.Step != StepRemove || !m.confirm.asking() {
		t.Fatalf("ctrl+d did not ask about the highlighted provider (step %v):\n%s", m.Step, ansi.Strip(m.View()))
	}
	m, cmd := m.Update(tea.KeyPressMsg{Code: 'x', Text: "x"})
	if cmd != nil || m.Step != StepRemove {
		t.Fatal("a stray key changed the removal question")
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if m.Step != StepChoose || m.confirm.asking() {
		t.Fatalf("esc did not keep the provider (step %v)", m.Step)
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'd', Mod: tea.ModCtrl})
	m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.Step != StepSaving || cmd == nil {
		t.Fatalf("enter did not remove (step %v)", m.Step)
	}
}

func TestLoginLetterInTheSearchFiltersInsteadOfRemoving(t *testing.T) {
	m := loginModel(120, 30)
	m, _ = m.Update(tea.KeyPressMsg{Code: 'd', Text: "d"})
	if m.Step != StepChoose || m.confirm.asking() {
		t.Fatalf("a bare letter started a removal (step %v)", m.Step)
	}
	if m.ChoosePicker.input.Value() != "d" {
		t.Fatalf("the letter did not reach the search: %q", m.ChoosePicker.input.Value())
	}
}

func TestLoginFilterFuzzilyFindsAProvider(t *testing.T) {
	m := loginModel(120, 30)
	for _, r := range "cla" {
		m, _ = m.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "claude-team") || strings.Contains(view, "Antigravity") {
		t.Fatalf("the search did not narrow to the claude providers:\n%s", view)
	}
	if item, ok := m.ChoosePicker.Highlighted(); !ok || !strings.HasPrefix(item.ID, "use:claude") && !strings.HasPrefix(item.ID, "signin:claude") {
		t.Fatalf("the best match is not a claude row: %+v", item)
	}
}

func TestLoginDetailShowsWithoutEnter(t *testing.T) {
	m := loginModel(120, 30)
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "a saved provider profile") {
		t.Fatalf("the highlighted provider's detail is not in the pane:\n%s", view)
	}
}

func TestLoginKeyEntryTakesLettersAsInput(t *testing.T) {
	m := loginModel(120, 30)
	m.askAPIKey()
	for _, r := range "dx" {
		m, _ = m.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	if m.TextInput.Value() != "dx" || m.Step != StepAPIKey {
		t.Fatalf("typing into the key step went elsewhere: %q on step %v", m.TextInput.Value(), m.Step)
	}
}
func TestServiceSignInCompletionSkipsModelsAndReturnsToChoose(t *testing.T) {
	m := loginModel(120, 30)
	serviceLogin := daemon.SignIn{Provider: "colab", Label: "Google Colab", Kind: "service", Flows: []string{"browser"}}
	m.SignIns = append(m.SignIns, serviceLogin)
	m.startSignIn(serviceLogin)

	serviceAcc := daemon.Account{ID: "acc-colab", Provider: "colab", Label: "colab-user@example.com", Kind: "service"}
	m, _ = m.Update(signInStatusMsg{
		State:    "complete",
		Accounts: []daemon.Account{serviceAcc},
		Gen:      m.Generation,
	})

	if m.Step != StepChoose {
		t.Fatalf("service login completion did not return to StepChoose, got: %v", m.Step)
	}
	if !strings.Contains(m.Status, "Signed in to Google Colab") {
		t.Fatalf("unexpected status after service login completion: %q", m.Status)
	}
	if m.Error != "" {
		t.Fatalf("unexpected error after service login completion: %q", m.Error)
	}
	found := false
	for _, acc := range m.Accounts {
		if acc.ID == "acc-colab" {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("new service account was not stored in model accounts")
	}
}

func TestServiceAccountSelectionDoesNotDraftModelProfile(t *testing.T) {
	m := loginModel(120, 30)
	serviceAcc := daemon.Account{ID: "acc-colab", Provider: "colab", Label: "colab-user@example.com", Kind: "service"}
	m.Accounts = append(m.Accounts, serviceAcc)
	m.buildChoosePicker()

	cmd := m.chooseAccount(serviceAcc)
	if cmd != nil {
		t.Fatalf("expected nil cmd for service account choose, got %v", cmd)
	}
	if m.Step != StepChoose {
		t.Fatalf("expected to remain on StepChoose, got %v", m.Step)
	}
	if !strings.Contains(m.Status, "ready for use with tools") {
		t.Fatalf("unexpected status: %q", m.Status)
	}
}

func TestServiceAccountAndSignInNotesInChoosePicker(t *testing.T) {
	m := loginModel(120, 30)
	m.SignIns = append(m.SignIns, daemon.SignIn{Provider: "colab", Label: "Google Colab", Kind: "service"})
	m.Accounts = append(m.Accounts, daemon.Account{ID: "acc-colab", Provider: "colab", Label: "colab-user@example.com", Kind: "service"})
	m.buildChoosePicker()

	var accountItem, signInItem *PickerItem
	for i := range m.ChoosePicker.items {
		item := &m.ChoosePicker.items[i]
		if strings.HasPrefix(item.ID, "account:") && item.Label == "colab-user@example.com" {
			accountItem = item
		}
		if item.ID == "signin:colab" {
			signInItem = item
		}
	}
	if accountItem == nil || accountItem.Note != "service account for tools; its tokens stay in creds.json" {
		t.Fatalf("unexpected service account note: %+v", accountItem)
	}
	if signInItem == nil || signInItem.Note != "service sign-in for tools; its tokens stay in creds.json" {
		t.Fatalf("unexpected service sign-in note: %+v", signInItem)
	}
}

