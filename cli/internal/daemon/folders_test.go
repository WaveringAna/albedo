// Host polling must address the probe target, not search known hosts. A
// controlled server makes the initial probing state deterministic.
package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"sync/atomic"
	"testing"
	"time"
)

func TestWarmHostPollsUnconfiguredTarget(t *testing.T) {
	for _, target := range []string{"new-host", "ana@new-host", "[::1]"} {
		t.Run(target, func(t *testing.T) {
			var probed atomic.Bool
			connection := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				host := map[string]any{
					"target": target, "state": "ready", "detail": nil,
					"os": nil, "architecture": nil, "home": nil,
					"observed_at": nil, "authentication": nil,
				}
				switch {
				case r.Method == http.MethodPost && r.URL.Path == "/hosts/"+target+"/probe":
					probed.Store(true)
					host["state"] = "probing"
					w.WriteHeader(http.StatusAccepted)
					_ = json.NewEncoder(w).Encode(host)
				case r.Method == http.MethodGet && r.URL.Path == "/hosts":
					if r.URL.Query().Get("target") == "" {
						_ = json.NewEncoder(w).Encode(map[string]any{"items": []any{}, "next": nil})
						return
					}
					if !probed.Load() || r.URL.Query().Get("target") != target {
						t.Errorf("unexpected host lookup: probed=%v query=%s", probed.Load(), r.URL.RawQuery)
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"items": []any{host}, "next": nil})
				default:
					t.Errorf("unexpected request: %s %s", r.Method, r.URL)
					http.NotFound(w, r)
				}
			})
			known, err := ListHosts(t.Context(), connection)
			if err != nil || len(known) != 0 {
				t.Fatalf("unconfigured host appeared in listing: %+v, %v", known, err)
			}
			ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
			defer cancel()
			status, err := WarmHost(ctx, connection, target)
			if err != nil || status.Host != target || status.State != "ready" {
				t.Fatalf("unconfigured probe did not settle: %+v, %v", status, err)
			}
		})
	}
}
