// Loaded commands and pages must remain usable when later discovery fails.
// A controlled peer fails catalog reads while keeping declared routes available.
package daemon

import (
	"encoding/json"
	"errors"
	"net/http"
	"testing"
)

func TestLoadedCommandsRemainReadableWhenDiscoveryFails(t *testing.T) {
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/sessions/s/catalog" {
			t.Errorf("unexpected catalog request: %s %s", r.Method, r.URL)
		}
		name := "/retained"
		var next *string
		if r.URL.Query().Get("next") == "" {
			next = new("loaded-page")
		} else {
			if r.URL.Query().Get("next") != "loaded-page" {
				t.Errorf("unexpected loaded continuation: %s", r.URL)
			}
			name = "/second"
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"discovery":         nil,
			"discovery_failure": map[string]any{"code": "discovery_unavailable", "detail": "Saved preferences cannot be read."},
			"loaded": map[string]any{"revision": "loaded-real", "next": next, "commands": []any{map[string]any{
				"id": "skills:" + name, "slash_name": name, "description": "Loaded skill", "arguments": []any{}, "caller_permissions": []string{"human"}, "delivery": "input", "command_id": name,
			}}},
		})
	})
	commands, err := ListSessionCommands(t.Context(), conn, "s")
	if err != nil || len(commands) != 2 || commands[0].CommandID != "/retained" || commands[1].CommandID != "/second" {
		t.Fatalf("loaded commands were erased by discovery failure: %+v %v", commands, err)
	}
	catalog, err := GetCapabilityCatalog(t.Context(), conn, "s")
	failure, ok := errors.AsType[*CatalogDiscoveryError](err)
	if !ok || failure.Code != "discovery_unavailable" || failure.Detail != "Saved preferences cannot be read." || catalog.Revision != "" {
		t.Fatalf("fresh discovery failure was hidden or assigned a revision: %+v %v", catalog, err)
	}
}

func TestLoadedPageUsesDeclaredReadWhenDiscoveryFails(t *testing.T) {
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sessions/s":
			_ = json.NewEncoder(w).Encode(canonicalSession("s", generationA, 0))
		case "/sessions/s/catalog":
			_, _ = w.Write([]byte(`{"discovery":null,"discovery_failure":{"code":"discovery_unavailable","detail":"unavailable"},"loaded":{"revision":"loaded","next":null,"commands":[{"id":"links","slash_name":"/link","description":"Links","arguments":[],"caller_permissions":["client"],"delivery":"read","operation":{"operation_id":"readCustomPage","method":"GET","path_template":"/extensions/custom/page","path":{},"headers":{},"body":{},"result_schema":{},"query":{"scope":{"source":"literal","value":"loaded"}}}}]}}`))
		case "/extensions/custom/page":
			if r.URL.Query().Get("scope") != "loaded" {
				t.Errorf("declared filter lost: %s", r.URL)
			}
			_, _ = w.Write([]byte(`{"page":{"title":"Retained page","empty_state":"Empty","rows":[],"glance":null,"actions":[],"summary":""}}`))
		default:
			t.Errorf("page guessed a route: %s", r.URL)
			w.WriteHeader(404)
		}
	})
	page, err := LoadPage(t.Context(), conn, "s", "/links")
	if err != nil || page.Title != "Retained page" {
		t.Fatalf("retained aliased page unavailable: %#v, %v", page, err)
	}
}
