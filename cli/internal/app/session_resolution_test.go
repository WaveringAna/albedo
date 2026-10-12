// A controlled daemon exposes unnecessary list requests and preserves exact
// error routing; real-daemon E2E covers the CLI commands and shortened IDs.
package app

import (
	"context"
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
			name: "exact match wins", requested: id[:8],
			ids: []string{id, id[:8]}, wantID: id[:8],
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

func TestPrepareOpenReusesBootstrapReads(t *testing.T) {
	const root = "019c1234-5678-7000-8000-000000000001"
	const child = "019c1234-5678-7000-8000-000000000002"
	for _, scenario := range []struct {
		name, requested, selected, wantError string
		roots                                []string
		status                               int
		cancel                               bool
	}{
		{name: "root full", requested: root, selected: root, roots: []string{root}},
		{name: "root prefix", requested: root[:8], selected: root, roots: []string{root}},
		{name: "child full", requested: child, selected: child, roots: []string{root}},
		{name: "missing full", requested: child, roots: []string{root}, status: http.StatusNotFound, wantError: "no session matches"},
		{name: "refused full", requested: child, roots: []string{root}, status: http.StatusForbidden, wantError: "refused"},
		{name: "cancelled capture", requested: child, roots: []string{root}, cancel: true},
		{name: "ambiguous prefix", requested: root[:8], roots: []string{root, child}, wantError: "more than one session ID"},
		{name: "missing prefix", requested: "missing", roots: []string{root}, wantError: "no session matches"},
		{name: "uppercase full", requested: strings.ToUpper(root), roots: []string{root}, wantError: "no session matches"},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			var paths []string
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				paths = append(paths, r.URL.RequestURI())
				w.Header().Set("Content-Type", "application/json")
				switch r.URL.Path {
				case "/sessions":
					if r.Method != http.MethodGet {
						t.Error("failed lookup attempted to create a replacement session")
						w.WriteHeader(http.StatusBadRequest)
						return
					}
					items := []any{}
					for _, id := range scenario.roots {
						items = append(items, testwire.Session(id, testwire.GenerationA, 0))
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"items": items, "next": nil})
				case "/settings":
					settings := testwire.Settings()
					settings["providers"].(map[string]any)["default_profile"] = "fixture"
					_ = json.NewEncoder(w).Encode(settings)
				case "/sessions/" + scenario.requested, "/sessions/" + scenario.selected:
					if scenario.cancel {
						cancel()
						<-r.Context().Done()
						return
					}
					if scenario.status != 0 {
						w.WriteHeader(scenario.status)
						_ = json.NewEncoder(w).Encode(map[string]any{"status": scenario.status, "code": "resource_not_found", "detail": "refused"})
						return
					}
					captured := testwire.Session(scenario.selected, testwire.GenerationA, 0)
					captured["name"] = "Captured session"
					_ = json.NewEncoder(w).Encode(captured)
				default:
					t.Errorf("unexpected request %s", r.URL.RequestURI())
					w.WriteHeader(http.StatusBadRequest)
				}
			}))
			defer server.Close()
			connection := daemon.NewConnection(daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
			defer connection.HTTPClient().CloseIdleConnections()
			service := Service{Connect: func(context.Context) (*daemon.Connection, error) { return connection, nil }}
			opened, err := service.PrepareOpen(ctx, OpenOptions{SessionID: scenario.requested, Workspace: "/bootstrap-work", Fresh: true})
			if scenario.cancel {
				if !errors.Is(err, context.Canceled) {
					t.Fatalf("lost cancellation: %v", err)
				}
			} else if scenario.wantError != "" {
				if err == nil || !strings.Contains(err.Error(), scenario.wantError) {
					t.Fatalf("lookup error=%v, want %q", err, scenario.wantError)
				}
				if scenario.status == http.StatusForbidden {
					if problem, ok := errors.AsType[*daemon.APIError](err); !ok || problem.StatusCode != http.StatusForbidden {
						t.Fatalf("lost original refusal: %v", err)
					}
				}
			} else {
				if err != nil || opened.Selected == nil || opened.Selected.ID != scenario.selected || opened.Selected.Title != "Captured session" {
					t.Fatalf("selected=%+v error=%v", opened.Selected, err)
				}
				count := 0
				for _, session := range opened.Sessions {
					if session.ID == scenario.selected {
						count++
						if session.Title != "Captured session" {
							t.Fatal("bootstrap retained stale root summary")
						}
					}
				}
				if count != 1 || opened.LoginRequired || opened.Workspace != "/bootstrap-work" || opened.Settings.Profiles.Active != "fixture" {
					t.Fatalf("bootstrap: selected count=%d, prepared=%+v", count, opened)
				}
				if scenario.selected == child && opened.Sessions[0].ID != child {
					t.Fatal("child was not prepended to bootstrap sessions")
				}
			}
			wantPaths := []string{"/sessions?scope=roots&limit=200"}
			if scenario.status != 0 || scenario.cancel || scenario.selected != "" {
				id := scenario.selected
				if id == "" {
					id = scenario.requested
				}
				wantPaths = append(wantPaths, "/settings", "/sessions/"+id+"?tail=0")
			}
			if !slices.Equal(paths, wantPaths) {
				t.Fatalf("requests=%v, want %v", paths, wantPaths)
			}
		})
	}
}
