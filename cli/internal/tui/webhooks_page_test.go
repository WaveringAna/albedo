// Webhook form differential updates, ephemeral secret protection, and session picker filtering.
// Differential step generation and modal reveal dismissal guards operate inside unexported
// form state; daemon E2E only sees executed RPCs and cannot verify zero-command emission.
package tui

import (
	"albedo/cli/internal/daemon"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

var webhookSessions = []daemon.Session{
	{ID: "s", Title: "infra bot", Workspace: "/srv/infra"},
	{ID: "t", Title: "release notes", Workspace: "/srv/docs"},
}

func loadedWebhooksPage(t *testing.T) WebhooksPageModel {
	t.Helper()
	m := NewWebhooksPageModel(nil, "s")
	m.SetSize(100, 30)
	m, _ = m.Update(webhooksLoadedMsg{Mounted: true, Sessions: webhookSessions, Hooks: []webhookEntry{
		{ID: "wh1", Session: "s", Name: "deploy", Enabled: true, URL: "/webhooks/wh1", Header: "x-hub-signature-256", Prefix: "sha256=", Queued: 2, Deferred: "session busy"},
		{ID: "wh2", Session: "t", Name: "grafana", URL: "/webhooks/wh2", Header: "x-albedo-signature", Prefix: "sha256="},
	}})
	return m
}

func TestWebhookEditOnlySendsWhatChanged(t *testing.T) {
	m := loadedWebhooksPage(t)
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.Form == nil || m.Form.current() != hookFieldSecret || m.Form.Chosen != "s" {
		t.Fatal("enter should edit the selected hook, starting at its secret")
	}
	if steps, _, _ := m.Form.steps(); len(steps) != 0 {
		t.Fatalf("unchanged form produced %v", steps)
	}
	m.Form.Inputs[hookFieldSecret].SetValue("a-new-sixteen-byte-secret")
	steps, _, err := m.Form.steps()
	if err != nil || len(steps) != 1 || steps[0] != [2]string{"rotate_with_secret", "wh1 a-new-sixteen-byte-secret"} {
		t.Fatalf("steps = %v, %v", steps, err)
	}
	if strings.Contains(m.View(), "a-new-sixteen-byte-secret") {
		t.Fatal("an entered secret was rendered")
	}
}

func TestGeneratedSecretIsShownUntilDismissed(t *testing.T) {
	m := loadedWebhooksPage(t)
	m.Saving = true
	m, _ = m.Update(webhooksSavedMsg{Gen: m.Generation, Notice: "added ci", Reveal: &webhookSecret{Hook: "ci", Secret: "whsec_generated"}})
	if !strings.Contains(m.View(), "whsec_generated") {
		t.Fatal("generated secret was not shown")
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'd', Text: "d"})
	if m.Reveal == nil || m.Confirm != "" {
		t.Fatal("keys other than enter must not dismiss the secret")
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.Reveal != nil || strings.Contains(m.View(), "whsec_generated") {
		t.Fatal("secret should be gone once dismissed")
	}
}

func TestWebhookFormPicksTheSessionToWake(t *testing.T) {
	m := loadedWebhooksPage(t)
	m, _ = m.Update(tea.KeyPressMsg{Code: 'n', Text: "n"})
	if m.Form.Chosen != "s" || !strings.Contains(ansi.Strip(m.View()), "session    this session · infra bot · /srv/infra") {
		t.Fatalf("the form should default to the session it was opened from:\n%s", ansi.Strip(m.View()))
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyTab, Mod: tea.ModShift})
	for _, r := range "release" {
		m, _ = m.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	if m.Form.Chosen != "t" {
		t.Fatalf("filtering should choose the matching session, got %q", m.Form.Chosen)
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyBackspace})
	m.Form.Inputs[hookFieldSession].SetValue("")
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyLeft})
	if m.Form.Chosen != "s" {
		t.Fatalf("← should step back to the first session, got %q", m.Form.Chosen)
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyRight})
	m.Form.Inputs[hookFieldName].SetValue("notes")
	steps, notice, err := m.Form.steps()
	if err != nil || steps[0] != [2]string{"create_in", "t notes"} || !strings.Contains(notice, "release notes") {
		t.Fatalf("steps = %v, %q, %v", steps, notice, err)
	}
}
