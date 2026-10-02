// Stale replies from closed capability pages must not satisfy reopened pages.
// E2E cannot deterministically interleave replies across discarded views.
package tui

import (
	"albedo/cli/internal/daemon"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

func TestCapabilityStaleReplyFromReplacedInstanceIsRejected(t *testing.T) {
	disabled := false
	key := "draft"
	items := []capabilityItem{{ID: "row-draft", Candidate: daemon.CatalogCandidate{PreferenceKey: &key, Valid: true, GlobalPreference: &disabled}}}
	a := NewCapabilityPageModel(nil, "s", "skills")
	a, _ = a.Update(capabilityLoadedMsg{Gen: a.Generation, Items: items, Revision: "rev-1"})
	a, _ = a.Update(tea.KeyPressMsg{Code: 'r'})
	zombie := capabilityLoadedMsg{Gen: a.Generation, Items: items, Revision: "rev-1"}
	a, _ = a.Update(tea.KeyPressMsg{Code: tea.KeyEscape})

	b := NewCapabilityPageModel(nil, "s", "skills")
	b, _ = b.Update(capabilityLoadedMsg{Gen: b.Generation, Items: items, Revision: "rev-1"})
	before := b.Generation
	b, _ = b.Update(tea.KeyPressMsg{Code: tea.KeySpace})
	if !b.Saving || b.Generation == before {
		t.Fatal("a toggle must start a save under a fresh generation")
	}
	saveGen := b.Generation
	b, _ = b.Update(capabilitySavedMsg{Gen: saveGen})
	if b.Saving || !b.Loading {
		t.Fatal("a completed save must fetch acknowledged state")
	}
	reloaded := capabilityLoadedMsg{Gen: b.Generation, Items: items, Revision: "rev-1"}
	if zombie.Gen == saveGen || zombie.Gen == reloaded.Gen {
		t.Fatal("generations collided across page instances")
	}
	b, _ = b.Update(zombie)
	if !b.Loading {
		t.Fatal("the discarded page's reply cleared the current fetch")
	}
	b, _ = b.Update(reloaded)
	if b.Loading || b.selectedEnabled(b.Items[0]) || len(b.Items) != 1 {
		t.Fatal("the current page's acknowledged state was not accepted")
	}
}

// The detached view owns response ordering and key routing, which daemon E2E
// scenarios cannot observe deterministically.
func TestCapabilityConflictRefreshesWithoutReplayingToggle(t *testing.T) {
	conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, nil)
	var methods []string
	conn.HTTPClient().Transport = catalogTransport(func(request *http.Request) (*http.Response, error) {
		methods = append(methods, request.Method)
		if request.URL.Path != "/sessions/s/catalog" {
			t.Fatalf("unexpected request path: %s", request.URL.Path)
		}
		status, body := http.StatusOK, ""
		switch {
		case len(methods) == 1 && request.Method == http.MethodPost:
			status, body = http.StatusConflict, `{"code":"stale_catalog","error":"catalog changed"}`
		case len(methods) == 2 && request.Method == http.MethodGet:
			body = `{"workspace":"/daemon-workspace","revision":"after","extensions":{"skills":true},"diagnostics":[],"candidates":[
				{"id":"row","kind":"skills","title":"Updated skill","source":"/skills/draft/SKILL.md","description":null,"resolved_source":null,"diagnostic":null,"shadowed_by":null,"preference_key":"draft","valid":true,"global_preference":false,"session_override":false,"effective_enabled":false,"eligible":false},
				{"id":"new-row","kind":"skills","title":"New skill","source":"/skills/new/SKILL.md","description":null,"resolved_source":null,"diagnostic":null,"shadowed_by":null,"global_preference":null,"session_override":null,"preference_key":"new","valid":true,"effective_enabled":true,"eligible":true}
			]}`
		default:
			t.Fatalf("unexpected request sequence: %v", methods)
		}
		return &http.Response{StatusCode: status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body))}, nil
	})
	key := "draft"
	item := capabilityItem{ID: "row", Title: "Original skill", Candidate: daemon.CatalogCandidate{PreferenceKey: &key, Valid: true, EffectiveEnabled: true}}
	m := NewCapabilityPageModel(conn, "s", "skills")
	m, _ = m.Update(capabilityLoadedMsg{Gen: m.Generation, Items: []capabilityItem{item}, Revision: "before"})
	m.Global = false
	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeySpace})
	if cmd == nil || !m.Saving {
		t.Fatal("toggle did not start a save")
	}
	m, cmd = m.Update(cmd())
	if m.Saving || !m.Loading || cmd == nil || !m.selectedEnabled(m.Items[0]) {
		t.Fatal("conflict must keep acknowledged choices and start a read")
	}
	m, cmd = m.Update(cmd())
	if cmd != nil || m.Loading || m.Saving || m.Error != "" || m.Revision != "after" {
		t.Fatal("refresh must adopt daemon state and wait for another user action")
	}
	if len(m.Items) != 2 || m.Items[0].Title != "Updated skill" || m.Items[1].ID != "new-row" || m.selectedEnabled(m.Items[0]) {
		t.Fatalf("refresh did not adopt changed rows and choices: %+v", m.Items)
	}
	candidate := m.Items[0].Candidate
	if candidate.GlobalPreference == nil || *candidate.GlobalPreference || candidate.SessionOverride == nil || *candidate.SessionOverride {
		t.Fatalf("refresh did not adopt daemon preferences: %+v", candidate)
	}
	if len(methods) != 2 || methods[0] != http.MethodPost || methods[1] != http.MethodGet {
		t.Fatalf("conflict must issue one POST followed by one GET: %v", methods)
	}
}

type catalogTransport func(*http.Request) (*http.Response, error)

func (transport catalogTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	return transport(request)
}

func TestCapabilityToggleSubmitsRowIdentityAndAcknowledgedRevision(t *testing.T) {
	conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, nil)
	requests := 0
	conn.HTTPClient().Transport = catalogTransport(func(request *http.Request) (*http.Response, error) {
		requests++
		var body struct {
			Enabled             *bool
			ID, Revision, Scope string
		}
		if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if request.URL.Path != "/sessions/s/catalog" || body.ID != "row-winner" || body.Revision != "current" || body.Scope != "session" || body.Enabled == nil || *body.Enabled {
			t.Fatalf("wrong catalog action: %s %+v", request.URL.Path, body)
		}
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(`{"reloaded":"session","message":"saved"}`))}, nil
	})
	key, winner := "shared-name", "row-winner"
	items := []capabilityItem{
		{ID: winner, Candidate: daemon.CatalogCandidate{PreferenceKey: &key, Valid: true, EffectiveEnabled: true}},
		{ID: "row-shadowed", Candidate: daemon.CatalogCandidate{PreferenceKey: &key, Valid: true, ShadowedBy: &winner, EffectiveEnabled: true}},
		{ID: "row-invalid", Candidate: daemon.CatalogCandidate{Valid: false}},
	}
	m := NewCapabilityPageModel(conn, "s", "skills")
	m, _ = m.Update(capabilityLoadedMsg{Gen: m.Generation, Items: items, Revision: "current"})
	m.Global = false
	for _, index := range []int{1, 2} {
		m.Cursor = index
		var cmd tea.Cmd
		m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeySpace})
		if cmd != nil || m.Saving {
			t.Fatal("shadowed or unaddressable invalid candidate accepted a toggle")
		}
	}
	m.Cursor = 0
	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeySpace})
	msg := cmd().(capabilitySavedMsg)
	if msg.Err != nil || requests != 1 || !m.Items[0].Candidate.EffectiveEnabled {
		t.Fatalf("toggle must send once without optimistic changes: %v", msg.Err)
	}
}
