package daemon

import (
	"encoding/json"
	"net/http"
	"testing"
)

func TestSignInListPopulatesKind(t *testing.T) {
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/auth" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"providers": []map[string]any{
				{
					"id":     "claude",
					"label":  "Claude",
					"detail": "console billing",
					"kind":   "model",
					"flows":  []string{"browser"},
					"fields": []any{},
				},
				{
					"id":     "colab",
					"label":  "Google Colab",
					"detail": "service account",
					"kind":   "service",
					"flows":  []string{"browser"},
					"fields": []any{},
				},
			},
			"accounts": []map[string]any{
				{
					"id":                   "acc-model",
					"provider":             "claude",
					"label":                "user@example.com",
					"detail":               "pro plan",
					"kind":                 "model",
					"selected_by_profiles": []string{"claude"},
				},
				{
					"id":                   "acc-service",
					"provider":             "colab",
					"label":                "service@example.com",
					"detail":               "colab tokens",
					"kind":                 "service",
					"selected_by_profiles": []string{},
				},
			},
		})
	})

	list, err := SignInList(t.Context(), conn)
	if err != nil {
		t.Fatalf("SignInList failed: %v", err)
	}
	if len(list.Logins) != 2 || list.Logins[0].Kind != "model" || list.Logins[1].Kind != "service" {
		t.Fatalf("unexpected logins kind: %+v", list.Logins)
	}
	if len(list.Accounts) != 2 || list.Accounts[0].Kind != "model" || list.Accounts[1].Kind != "service" {
		t.Fatalf("unexpected accounts kind: %+v", list.Accounts)
	}
}
