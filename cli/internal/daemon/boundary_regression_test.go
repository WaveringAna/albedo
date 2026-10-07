// Controlled cancellation and malformed wire batches cannot be forced reliably
// through a scripted provider; these tests exercise the public transport boundaries.
package daemon

import (
	"albedo/cli/internal/daemon/protocol"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"testing"
)

func TestAgentEventsValidateNullableSendersAndBooleanFields(t *testing.T) {
	event, err := decodeAgentEvent(json.RawMessage(`{"type":"mail","data":{"mail_id":"m","sender_session_id":null,"sender_label":null,"receiver_session_id":"s","kind":"message","bytes":2}}`))
	if err != nil || event == nil || event.To != "s" {
		t.Fatalf("nullable bus sender rejected: %v", err)
	}
	if _, err := decodeAgentEvent(json.RawMessage(`{"type":"invalidate","data":{"urls":[],"session_ids":["s"],"scope_dirty":"false"}}`)); err == nil {
		t.Fatal("malformed bus boolean accepted")
	}
}

// Presence and null differ even when Go would decode both as the same zero.
// A controlled peer can violate these contracts at every nested boundary.
func TestSessionReadValidatesRequiredAndNullableMembers(t *testing.T) {
	for _, scenario := range []struct {
		name   string
		change func(map[string]any)
		valid  bool
	}{
		{"required nullable omitted", func(session map[string]any) { delete(session, "effort") }, false},
		{"nullable retained", func(session map[string]any) { session["effort"] = nil }, true},
		{"nested required omitted", func(session map[string]any) {
			delete(session["kernel"].(map[string]any), "live_job_count")
		}, false},
		{"nested nullable retained", func(session map[string]any) {
			session["kernel"].(map[string]any)["live_job_count"] = nil
		}, true},
		{"job list omitted", func(session map[string]any) {
			delete(session["kernel"].(map[string]any), "running_jobs")
		}, false},
		{"unknown job list", func(session map[string]any) {
			session["kernel"].(map[string]any)["running_jobs"] = nil
		}, true},
		{"job pid omitted", func(session map[string]any) {
			session["kernel"].(map[string]any)["running_jobs"] = []any{map[string]any{"id": "j", "command": "sleep 10"}}
		}, false},
		{"nullable job pid", func(session map[string]any) {
			session["kernel"].(map[string]any)["running_jobs"] = []any{map[string]any{"id": "j", "pid": nil, "command": "sleep 10", "started_at": 0}}
		}, true},
		{"job started_at omitted", func(session map[string]any) {
			session["kernel"].(map[string]any)["running_jobs"] = []any{map[string]any{"id": "j", "pid": nil, "command": "sleep 10"}}
		}, false},
		{"null scalar", func(session map[string]any) {
			session["status"].(map[string]any)["interrupt_requested"] = nil
		}, false},
		{"null array", func(session map[string]any) { session["glances"] = nil }, false},
		{"null object", func(session map[string]any) { session["preferences"] = nil }, false},
		{"optional progress preview omitted", func(session map[string]any) {
			progress := canonicalProgress("call")
			delete(progress, "preview")
			session["current_progress"] = []any{progress}
		}, true},
		{"optional progress preview null", func(session map[string]any) {
			progress := canonicalProgress("call")
			progress["preview"] = nil
			session["current_progress"] = []any{progress}
		}, false},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			session := canonicalSession("s", generationA, 0)
			scenario.change(session)
			conn := controlledConnection(t, func(w http.ResponseWriter, request *http.Request) {
				if request.URL.RequestURI() != "/sessions/s?tail=0" {
					t.Errorf("unexpected session read %s", request.URL)
				}
				_ = json.NewEncoder(w).Encode(session)
			})
			captured, err := GetSession(t.Context(), conn, "s")
			if scenario.valid {
				if err != nil || captured.ID != "s" {
					t.Fatalf("nullable native fact rejected: %+v, %v", captured, err)
				}
			} else if _, ok := errors.AsType[*ProtocolError](err); !ok {
				t.Fatalf("malformed required member accepted: %v", err)
			}
		})
	}
}

func TestSessionChangeRejectsMissingNestedMembers(t *testing.T) {
	for _, valid := range []bool{true, false} {
		session := canonicalSession("s", generationA, 0)
		if !valid {
			delete(session["kernel"].(map[string]any), "live_job_count")
		}
		payload, err := json.Marshal(map[string]any{"session": session, "resource": session["configuration_resource"], "move": nil})
		if err != nil {
			t.Fatal(err)
		}
		var change protocol.SessionChange
		err = decodeRequired(payload, &change)
		if (err == nil) != valid {
			t.Fatalf("nested session validation valid=%v: %v", valid, err)
		}
	}
}

func TestModelPagingRejectsRepeatedTokens(t *testing.T) {
	calls := 0
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 && r.URL.Query().Get("next") != "" || calls == 2 && r.URL.Query().Get("next") != "same" {
			t.Errorf("wrong cursor at page %d: %s", calls, r.URL)
		}
		_, _ = fmt.Fprint(w, `{"items":[],"next":"same"}`)
	})
	if _, err := ListModels(t.Context(), conn, "provider", ""); err == nil || calls != 2 {
		t.Fatalf("repeated cursor accepted: calls=%d, error=%v", calls, err)
	}
}
