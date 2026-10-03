// Stale replies from closed capability pages must not satisfy reopened pages.
// E2E cannot deterministically interleave replies across discarded views.
package tui

import (
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/testwire"
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
	var methods []string
	conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
		methods = append(methods, r.Method)
		status := 200
		var body any
		switch {
		case len(methods) == 1 && r.Method == http.MethodPatch:
			if r.URL.RequestURI() != "/sessions/s?view=configuration" {
				t.Fatalf("wrong mutation %s", r.URL)
			}
			status = 409
			body = map[string]any{"type": "about:blank", "title": "Catalog changed", "status": 409, "code": "catalog_changed", "detail": "catalog changed"}
		case r.URL.Path == "/sessions/s/catalog":
			body = map[string]any{"discovery": map[string]any{"workspace": "/daemon-workspace", "revision": "after", "candidates": []any{protocolCandidate("row", "Updated skill", false), protocolCandidate("new-row", "New skill", true)}, "diagnostics": []any{}, "next": nil}, "discovery_failure": nil, "loaded": map[string]any{"revision": nil, "commands": []any{}, "next": nil}}
		case r.URL.Path == "/settings":
			body = testwire.Settings()
		case r.URL.Path == "/sessions/s":
			body = protocolSession("s", generationA, 0)["configuration_resource"].(map[string]any)["value"]
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL)
		}
		w.Header().Set("ETag", "\"after\"")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(body)
	})
	key := "draft"
	item := capabilityItem{ID: "row", Title: "Original skill", Candidate: daemon.CatalogCandidate{ID: "row", PreferenceKey: &key, Valid: true, EffectiveEnabled: true}}
	m := NewCapabilityPageModel(conn, "s", "skills")
	m, _ = m.Update(capabilityLoadedMsg{Gen: m.Generation, Items: []capabilityItem{item}, Revision: "before", SessionETag: "\"seen\""})
	m.Global = false
	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeySpace})
	m, cmd = m.Update(cmd())
	if m.Saving || !m.Loading || cmd == nil || !m.selectedEnabled(m.Items[0]) {
		t.Fatal("conflict must preserve acknowledged choices and start a read")
	}
	m, cmd = m.Update(cmd())
	if cmd != nil || m.Loading || m.Error != "" || m.Revision != "after" || len(m.Items) != 2 {
		t.Fatalf("refresh did not adopt catalog %+v", m)
	}
	first := m.Items[1]
	if first.ID != "row" {
		first = m.Items[0]
	}
	if m.selectedEnabled(first) || first.Candidate.SessionOverride == nil {
		t.Fatalf("fresh disabled row lost %+v", first)
	}
	if len(methods) != 4 || methods[0] != "PATCH" {
		t.Fatalf("toggle replayed or missing canonical reads %v", methods)
	}
}
func protocolCandidate(id, title string, enabled bool) map[string]any {
	return map[string]any{"id": id, "kind": "skill", "title": title, "description": "", "source": "/skills/" + id, "resolved_source": nil, "preference_key": "skill:" + id, "valid": true, "eligible": enabled, "effective_enabled": enabled, "global_preference": enabled, "session_override": enabled, "shadowed_by": nil, "dependencies": []any{}, "quarantined": false, "diagnostic": nil, "extension": nil}
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
			CatalogRevision string `json:"catalog_revision"`
			Selection       struct {
				Skills map[string]*bool `json:"skills"`
			} `json:"selection"`
		}
		if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		choice := body.Selection.Skills["row-winner"]
		if request.Method != "PATCH" || request.URL.RequestURI() != "/sessions/s?view=configuration" || request.Header.Get("If-Match") != "\"seen\"" || body.CatalogRevision != "current" || choice == nil || *choice {
			t.Fatalf("wrong observed selection %s %+v", request.URL, body)
		}
		session := protocolSession("s", generationA, 0)
		resource := session["configuration_resource"]
		encoded, _ := json.Marshal(map[string]any{"resource": resource, "session": session, "move": nil})
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(string(encoded)))}, nil
	})
	key, winner := "shared-name", "row-winner"
	items := []capabilityItem{
		{ID: winner, Candidate: daemon.CatalogCandidate{PreferenceKey: &key, Valid: true, EffectiveEnabled: true}},
		{ID: "row-shadowed", Candidate: daemon.CatalogCandidate{PreferenceKey: &key, Valid: true, ShadowedBy: &winner, EffectiveEnabled: true}},
		{ID: "row-invalid", Candidate: daemon.CatalogCandidate{Valid: false}},
	}
	m := NewCapabilityPageModel(conn, "s", "skills")
	m, _ = m.Update(capabilityLoadedMsg{Gen: m.Generation, Items: items, Revision: "current", SessionETag: "\"seen\""})
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
