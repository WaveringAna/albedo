// Controlled peers exercise delivery and failure behavior the real daemon cannot force deterministically.
package daemon

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"

	"albedo/cli/internal/daemon/protocol"
)

func TestDeclaredActionRejectsOverlappingBodyBindingsBeforeDelivery(t *testing.T) {
	var delivered atomic.Int32
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		delivered.Add(1)
		_, _ = w.Write([]byte(`{}`))
	})
	for _, body := range []string{
		`{"/a":{"source":"literal","value":{}},"/a/b":{"source":"literal","value":1}}`,
		`{"/a/b":{"source":"literal","value":1},"/a":{"source":"literal","value":{}}}`,
		`{"/a~1b":{"source":"literal","value":{}},"/a~1b/c":{"source":"literal","value":1}}`,
	} {
		var action PageAction
		if err := json.Unmarshal([]byte(`{"method":"POST","path_template":"/extensions/custom/items","body":`+body+`}`), &action.Operation); err != nil {
			t.Fatal(err)
		}
		if _, err := ExecutePageAction(t.Context(), conn, PageActionRequest{Action: action}); err == nil {
			t.Errorf("overlapping body was accepted: %s", body)
		}
	}
	if count := delivered.Load(); count != 0 {
		t.Fatalf("ambiguous actions reached the daemon %d times", count)
	}
}

func TestDeclaredActionDeliversSiblingAndEscapedBodyKeys(t *testing.T) {
	var delivered atomic.Int32
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
			return
		}
		nested, ok := body["a/b"].(map[string]any)
		if !ok || nested["~name"] != "one" || nested["second"] != "two" || body["a"] != "separate" {
			t.Errorf("body bindings changed: %#v", body)
		}
		delivered.Add(1)
		_, _ = w.Write([]byte(`{}`))
	})
	var action PageAction
	if err := json.Unmarshal([]byte(`{"method":"POST","path_template":"/extensions/custom/items","body":{"/a~1b/~0name":{"source":"literal","value":"one"},"/a~1b/second":{"source":"literal","value":"two"},"/a":{"source":"literal","value":"separate"}}}`), &action.Operation); err != nil {
		t.Fatal(err)
	}
	if _, err := ExecutePageAction(t.Context(), conn, PageActionRequest{Action: action}); err != nil {
		t.Fatal(err)
	}
	if delivered.Load() != 1 {
		t.Fatal("valid action was not delivered")
	}
}

func TestDeclaredActionCapturesRowBindingsAndValidatesResult(t *testing.T) {
	var row PageRow
	if err := json.Unmarshal([]byte(`{"id":"row-a","text":"Task","badge":null,"tone":"plain","detail":null,"resource":{"url":"/extensions/custom/items/row-a","etag":"\"seen\"","value":{"title":"displayed title"}}}`), &row.wire); err != nil {
		t.Fatal(err)
	}
	var field FormField
	_ = json.Unmarshal([]byte(`{"name":"title","label":"Title","type":"text","required":true,"default":"literal","default_binding":{"source":"row","pointer":"/resource/value/title"}}`), &field)
	resolved, err := ResolveFormField(field, &row, nil)
	if err != nil || string(resolved.Default) != `"displayed title"` {
		t.Fatalf("row prefill was lost: %s %v", resolved.Default, err)
	}
	resolved.Required = false
	if cleared, err := ParseActionField(resolved, ""); err != nil || string(cleared) != `""` {
		t.Fatalf("clearing a prefilled text field restored its old value: %s %v", cleared, err)
	}
	field.DefaultBinding.Pointer = "/resource"
	if _, err := ResolveFormField(field, &row, nil); err == nil {
		t.Fatal("object prefill accepted for text field")
	}
	for _, scenario := range []string{"valid", "bad result", "bad schema"} {
		t.Run(scenario, func(t *testing.T) {
			var calls atomic.Int32
			conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				if r.Method != http.MethodPatch || r.URL.String() != "/extensions/custom/items/row-a" || r.Header.Get("If-Match") != `"seen"` {
					t.Errorf("displayed binding not captured: %s %s %v", r.Method, r.URL, r.Header)
				}
				var body map[string]any
				_ = json.NewDecoder(r.Body).Decode(&body)
				if len(body) != 1 || body["title"] != "edited title" {
					t.Errorf("optional form field became a write: %v", body)
				}
				if scenario == "bad result" {
					_, _ = io.WriteString(w, `{"saved":"yes"}`)
				} else {
					_, _ = io.WriteString(w, `{"saved":true}`)
				}
			})
			var operation protocol.ActionOperation
			if err := json.Unmarshal([]byte(`{"operation_id":"editCustomItem","method":"PATCH","path_template":"/extensions/custom/items/{id}","path":{"id":{"source":"row","pointer":"/id"}},"query":{},"headers":{"If-Match":{"source":"row","pointer":"/resource/etag"}},"body":{"/title":{"source":"form","pointer":"/title"},"/notes":{"source":"form","pointer":"/notes"}},"result_schema":{"type":"object","required":["saved"],"properties":{"saved":{"type":"boolean"}}}}`), &operation); err != nil {
				t.Fatal(err)
			}
			if scenario == "bad schema" {
				operation.ResultSchema = json.RawMessage(`{"$ref":"https://untrusted.example/schema"}`)
			}
			_, err := executeBoundOperation(t.Context(), conn, operation, &row, map[string]json.RawMessage{"title": json.RawMessage(`"edited title"`)}, nil)
			switch scenario {
			case "valid":
				if err != nil || calls.Load() != 1 {
					t.Fatalf("valid action failed: %v count=%d", err, calls.Load())
				}
			case "bad result":
				if _, uncertain := errors.AsType[*UncertainOutcomeError](err); !uncertain || calls.Load() != 1 {
					t.Fatalf("invalid result lost uncertainty or replayed: %v count=%d", err, calls.Load())
				}
			case "bad schema":
				if err == nil || calls.Load() != 0 {
					t.Fatalf("unresolvable schema caused an effect: %v count=%d", err, calls.Load())
				}
			}
		})
	}
}

// Input commands and HTTP operations are different catalog variants. An input
// must not require a fabricated operation descriptor or use a public dispatcher.

func TestAdvertisedInputCommandUsesChosenInputResource(t *testing.T) {
	command, err := decodeSessionCommand(json.RawMessage(`{"id":"declared","slash_name":"/declared","description":"Run a declared input","arguments":[],"caller_permissions":["client","model"],"delivery":"input","command_id":"extension.command"}`))
	if err != nil {
		t.Fatal(err)
	}
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPut || !strings.HasPrefix(r.URL.Path, "/sessions/s/inputs/") {
			t.Errorf("input command used another contract: %s %s", r.Method, r.URL)
		}
		var body struct {
			Kind      string                     `json:"kind"`
			CommandID string                     `json:"command_id"`
			Arguments map[string]json.RawMessage `json:"arguments"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Kind != "command" || body.CommandID != "extension.command" || string(body.Arguments["structured"]) != `{"enabled":true}` {
			t.Errorf("structured input intent changed: %#v %v", body, err)
		}
		id := strings.TrimPrefix(r.URL.Path, "/sessions/s/inputs/")
		w.WriteHeader(http.StatusAccepted)
		_ = json.NewEncoder(w).Encode(canonicalInput("s", id, "command", "pending"))
	})
	result, err := InvokeDeclaredCommand(t.Context(), conn, Session{ID: "s"}, command, map[string]json.RawMessage{"structured": json.RawMessage(`{"enabled":true}`)})
	if err != nil || !result.Submitted {
		t.Fatalf("declared input was not admitted: %#v %v", result, err)
	}
}

func TestDeclaredReadActionKeepsItsCapturedFilterOnRefresh(t *testing.T) {
	reads := 0
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Errorf("read caused a mutation: %s", r.Method)
		}
		if r.URL.Path == "/sessions/s" {
			_ = json.NewEncoder(w).Encode(canonicalSession("s", generationA, 0))
			return
		}
		if r.URL.String() != "/extensions/custom/items?scope=all" {
			t.Errorf("captured filter was lost: %s", r.URL)
		}
		reads++
		_ = json.NewEncoder(w).Encode(map[string]any{"items": []any{map[string]any{"version": reads, "exact": json.Number("9007199254740993")}}})
	})
	var action PageAction
	if err := json.Unmarshal([]byte(`{"operation_id":"readCustomItems","method":"GET","path_template":"/extensions/custom/items","path":{},"query":{"scope":{"source":"form","pointer":"/scope"}},"headers":{},"body":{},"result_schema":{}}`), &action.Operation); err != nil {
		t.Fatal(err)
	}
	action.Label = "Custom items"
	form := map[string]json.RawMessage{"scope": json.RawMessage(`"all"`)}
	result, err := ExecutePageAction(t.Context(), conn, PageActionRequest{Action: action, Form: form, Session: &Session{ID: "s"}})
	if err != nil || result.Page == nil || !strings.Contains(result.Page.Rows[0].Detail, `"version": 1`) || !strings.Contains(result.Page.Rows[0].Detail, `9007199254740993`) {
		t.Fatalf("read result was discarded: %#v %v", result, err)
	}
	form["scope"] = json.RawMessage(`"edited"`)
	refreshed, err := RefreshPage(t.Context(), conn, "s", "/custom", result.Page)
	if err != nil || reads != 2 || !strings.Contains(refreshed.Rows[0].Detail, `"version": 2`) {
		t.Fatalf("read refresh changed its intent: %#v %v", refreshed, err)
	}
}

// Adjacent arbitrary JSON integers can identify different domain choices and
// tool arguments. A float64 intermediate silently changes the selected value.
