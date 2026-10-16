// Login's lists and removal question are keystroke behaviour the e2e suite
// reaches only through the daemon's flows: a letter typed into the always-live
// search must not remove a provider (the old bare "d" did), removal waits for
// enter, and a text step takes letters as input rather than as actions.
package tui

import (
	"albedo/cli/internal/daemon"
	"fmt"
	"slices"
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
	if !strings.Contains(view, "endpoint") || !strings.Contains(view, "api.openai.com") {
		t.Fatalf("the highlighted profile's facts are not in the pane:\n%s", view)
	}
}

// The accounts picker lists four kinds of row under rules of their own, so a
// person can see what a row is before pressing enter, and no row is cut off
// before the word that names it.
func TestChoosePickerGroupsEveryKindUnderItsOwnRule(t *testing.T) {
	m := loginModel(120, 30)
	view := ansi.Strip(m.View())
	for _, rule := range []string{"providers 3", "accounts 1", "sign in 2", fmt.Sprintf("add a provider %d", len(customProviders))} {
		if !strings.Contains(view, rule) {
			t.Fatalf("the list is missing the %q rule:\n%s", rule, view)
		}
	}
	for _, label := range []string{"OpenCode Go", "OpenAI-compatible", "Antigravity"} {
		if !strings.Contains(view, label) {
			t.Fatalf("the list is missing %q, or cuts it short:\n%s", label, view)
		}
	}
	if strings.Contains(view, "add or update") {
		t.Fatalf("the add rows repeat the words their rule already says:\n%s", view)
	}
	sections := map[string]string{}
	for _, item := range m.ChoosePicker.items {
		sections[item.ID] = item.section
	}
	for id, want := range map[string]string{
		"use:work":      sectionProviders,
		"account:0":     sectionAccounts,
		"signin:claude": sectionSignIn,
		"add-alibaba":   sectionAdd,
	} {
		if sections[id] != want {
			t.Fatalf("%s sits under %q, want %q", id, sections[id], want)
		}
	}
}

// Accounts of one provider can carry the same label, and their rows then read
// alike; the pane names the account it is showing only when it has to.
func TestAccountPaneNamesTheIDWhenLabelsCollide(t *testing.T) {
	m := loginModel(120, 30)
	focusLoginRow(&m, "account:0")
	if view := ansi.Strip(m.View()); strings.Contains(view, "acc-1") {
		t.Fatalf("a label of its own does not need the id:\n%s", view)
	}
	m.Accounts = append(m.Accounts, daemon.Account{Provider: "claude", ID: "0123456789abcdef", Label: "mayer@chernobog", Detail: "Max plan"})
	m.buildChoosePicker()
	for id, want := range map[string]string{"account:0": "acc-1", "account:1": "01234567"} {
		focusLoginRow(&m, id)
		if view := ansi.Strip(m.View()); !strings.Contains(view, want) {
			t.Fatalf("the pane for %s does not name the account it shows:\n%s", id, view)
		}
	}
}

// Enter is named per row: a service account is ready as it stands, so its row
// offers no enter at all.
func TestEnterVerbFollowsTheRow(t *testing.T) {
	m := loginModel(120, 30)
	m.Accounts = append(m.Accounts, daemon.Account{Provider: "colab", ID: "acc-colab", Label: "colab-user@example.com", Detail: "", Kind: "service"})
	m.buildChoosePicker()
	for id, want := range map[string]string{
		"use:work":      "use",
		"account:0":     "use",
		"account:1":     "",
		"signin:claude": "sign in",
		"add-alibaba":   "set up",
	} {
		focusLoginRow(&m, id)
		if got := m.enterVerb(); got != want {
			t.Fatalf("enter on %s is %q, want %q", id, got, want)
		}
	}
}

// focusLoginRow puts the cursor on the row keyed id, so a test can read what
// that row says and offers.
func focusLoginRow(m *LoginModel, id string) {
	if i := slices.IndexFunc(m.ChoosePicker.shown, func(s listShown) bool { return m.ChoosePicker.rows[s.row].key == id }); i >= 0 {
		m.ChoosePicker.Cursor = i
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

	var accountItem, signInItem *loginItem
	for i := range m.ChoosePicker.items {
		item := &m.ChoosePicker.items[i]
		if strings.HasPrefix(item.ID, "account:") && item.Label == "colab-user@example.com" {
			accountItem = item
		}
		if item.ID == "signin:colab" {
			signInItem = item
		}
	}
	if accountItem == nil || accountItem.note != "service account for tools; its tokens stay in creds.json" {
		t.Fatalf("unexpected service account note: %+v", accountItem)
	}
	if signInItem == nil || signInItem.note != "service sign-in for tools; its tokens stay in creds.json" {
		t.Fatalf("unexpected service sign-in note: %+v", signInItem)
	}
}
