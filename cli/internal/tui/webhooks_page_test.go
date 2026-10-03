// Webhook form differential updates, ephemeral secret protection, and session picker filtering.
// Differential step generation and modal reveal dismissal guards operate inside unexported
// form state; daemon E2E only sees submitted mutations and cannot verify an unchanged form.
package tui

import (
	"albedo/cli/internal/daemon"
	"errors"
	"net/http"
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
	m, _ = m.Update(webhooksLoadedMsg{Gen: m.Generation, Mounted: true, Sessions: webhookSessions, Hooks: []webhookEntry{
		{ID: "wh1", Session: "s", Name: "deploy", Enabled: true, URL: "/extensions/webhooks/hooks/wh1/deliveries", Header: "x-hub-signature-256", Prefix: "sha256=", Queued: 2, Deferred: "session busy"},
		{ID: "wh2", Session: "t", Name: "grafana", URL: "/extensions/webhooks/hooks/wh2/deliveries", Header: "x-albedo-signature", Prefix: "sha256="},
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
	if err != nil || len(steps) != 1 || steps[0] != (daemon.WebhookRequest{Action: daemon.WebhookRotate, HookID: "wh1", Secret: "a-new-sixteen-byte-secret"}) {
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
	if err != nil || steps[0] != (daemon.WebhookRequest{Action: daemon.WebhookCreate, SessionID: "t", Name: "notes", Header: "x-albedo-signature", Prefix: "sha256="}) || !strings.Contains(notice, "release notes") {
		t.Fatalf("steps = %v, %q, %v", steps, notice, err)
	}
}

// A failed extension read cannot establish that deliveries are mounted.
func TestWebhookLoadSurfacesExtensionFailure(t *testing.T) {
	requests := 0
	conn := commandTestConnection(t, func(w http.ResponseWriter, _ *http.Request) {
		requests++
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"detail":"extension load refused"}`))
	})
	m := NewWebhooksPageModel(conn, "session")
	msg := m.loadCmd(m.Generation)().(webhooksLoadedMsg)
	if msg.Err == nil || msg.Mounted || requests != 1 {
		t.Fatalf("extension failure treated as mounted: %+v requests=%d", msg, requests)
	}
	m, _ = m.Update(msg)
	if m.Loaded || m.Error == "" {
		t.Fatal("extension failure did not surface in screen")
	}
}

// Creation is already committed when a following signature update fails.
func TestWebhookSaveRetainsCreatedSecretAfterLaterFailure(t *testing.T) {
	requests := 0
	conn := commandTestConnection(t, func(w http.ResponseWriter, _ *http.Request) {
		requests++
		if requests == 1 {
			w.WriteHeader(201)
			_, _ = w.Write([]byte(`{"resource":{"url":"/extensions/webhooks/hooks/created?view=configuration","etag":"\"created-a\"","value":{"id":"created","session_id":"session","name":"deploy","signature_header":"x-albedo-signature","signature_prefix":"sha256=","enabled":true,"revision":"a","created_at":"2026-10-03T00:00:00Z","updated_at":"2026-10-03T00:00:00Z"}},"secret":"whsec_created","notification":{"state":"not_requested","code":null,"detail":null}}`))
			return
		}
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"detail":"signature refused"}`))
	})
	m := NewWebhooksPageModel(conn, "session")
	msg := m.save(m.Generation, "added", daemon.WebhookRequest{Action: daemon.WebhookCreate, SessionID: "session", Name: "deploy"}, daemon.WebhookRequest{Action: daemon.WebhookSignature, Header: "x-custom", Prefix: ""})().(webhooksSavedMsg)
	if msg.Err == nil || msg.Reveal == nil || msg.Reveal.Secret != "whsec_created" || requests != 2 {
		t.Fatalf("lost committed secret: %+v requests=%d", msg, requests)
	}
	var apiErr *daemon.APIError
	if !errors.As(msg.Err, &apiErr) {
		t.Fatalf("lost failure: %v", msg.Err)
	}
	m, _ = m.Update(msg)
	if m.Reveal == nil || m.Error == "" {
		t.Fatal("partial success did not retain reveal and error")
	}
}
