// A controlled daemon exposes unnecessary list requests and preserves exact
// error routing; real-daemon E2E covers the CLI commands and shortened IDs.
package app

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/testwire"
)

func TestSessionResolutionReadsFullIDsAndListsOnlyPrefixes(t *testing.T) {
	const id = "019c1234-5678-7000-8000-000000000001"
	const sibling = "019c1234-5678-7000-8000-000000000002"
	for _, scenario := range []struct {
		name, requested, wantID, wantError string
		status                             int
		ids                                []string
		paths                              []string
	}{
		{
			name: "full", requested: id, wantID: id,
			paths: []string{"/sessions/" + id + "?view=configuration"},
		},
		{
			name: "missing full", requested: id, status: 404,
			wantError: fmt.Sprintf("no session matches %q; run albedo sessions to see the available sessions", id),
			paths:     []string{"/sessions/" + id + "?view=configuration"},
		},
		{
			name: "refused full", requested: id,
			status: 403, wantError: "refused",
			paths: []string{"/sessions/" + id + "?view=configuration"},
		},
		{
			name: "prefix", requested: id[:8],
			ids: []string{id}, wantID: id,
			paths: []string{"/sessions?scope=roots&limit=200"},
		},
		{
			name: "ambiguous prefix", requested: id[:8],
			ids: []string{id, sibling}, wantError: "more than one session ID",
			paths: []string{"/sessions?scope=roots&limit=200"},
		},
		{
			name: "missing prefix", requested: "missing",
			wantError: "no session matches",
			paths:     []string{"/sessions?scope=roots&limit=200"},
		},
		{
			name: "uppercase stays exact", requested: strings.ToUpper(id),
			wantError: "no session matches",
			paths:     []string{"/sessions?scope=roots&limit=200"},
		},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			var paths []string
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				paths = append(paths, r.URL.RequestURI())
				w.Header().Set("Content-Type", "application/json")
				if scenario.status != 0 {
					w.WriteHeader(scenario.status)
					_ = json.NewEncoder(w).Encode(map[string]any{"status": scenario.status, "code": "resource_not_found", "detail": "refused"})
					return
				}
				if r.URL.Path == "/sessions" {
					items := []any{}
					for _, sessionID := range scenario.ids {
						items = append(items, testwire.Session(sessionID, testwire.GenerationA, 0))
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"items": items, "next": nil})
					return
				}
				session := testwire.Session(id, testwire.GenerationA, 0)
				resource := session["configuration_resource"].(map[string]any)
				w.Header().Set("ETag", resource["etag"].(string))
				_ = json.NewEncoder(w).Encode(resource["value"])
			}))
			defer server.Close()
			connection := daemon.NewConnection(daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
			defer connection.HTTPClient().CloseIdleConnections()
			resolved, err := resolveSession(t.Context(), connection, scenario.requested)
			if resolved != scenario.wantID || (scenario.wantError == "" && err != nil) || (scenario.wantError != "" && (err == nil || !strings.Contains(err.Error(), scenario.wantError))) {
				t.Fatalf("resolution: id=%q error=%v", resolved, err)
			}
			if scenario.status == 403 {
				if problem, ok := errors.AsType[*daemon.APIError](err); !ok || problem.StatusCode != 403 {
					t.Fatalf("lost original refusal: %v", err)
				}
			}
			if !slices.Equal(paths, scenario.paths) {
				t.Fatalf("requests=%v, want %v", paths, scenario.paths)
			}
		})
	}
}
