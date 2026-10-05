// Authentication recovery must retry the captured flow and secret fields.
// A controlled peer changes discovery between attempts to expose rebinding.
package daemon

import (
	"encoding/json"
	"io"
	"net/http"
	"testing"
)

func TestLoginRetryFreezesAdvertisedFlowAndSecretFields(t *testing.T) {
	values := map[string]json.RawMessage{"tenant": json.RawMessage(`"original"`), "secret": json.RawMessage(`"one-time-secret"`)}
	var admitted []string
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/auth/logins/chosen-login" {
			t.Errorf("changed login identity: %s", r.URL)
		}
		if r.Method == http.MethodGet {
			w.WriteHeader(404)
			_, _ = io.WriteString(w, `{"type":"about:blank","title":"Not found","status":404,"code":"not_found","detail":"No retained login"}`)
			return
		}
		if r.Method != http.MethodPut {
			t.Errorf("wrong login admission method %s", r.Method)
		}
		body, _ := io.ReadAll(r.Body)
		admitted = append(admitted, string(body))
		if len(admitted) == 1 {
			values["secret"] = json.RawMessage(`"edited-after-send"`)
			delete(values, "tenant")
			w.WriteHeader(201)
			_, _ = io.WriteString(w, `{"invalid":"acknowledgment"}`)
			return
		}
		w.Header().Set("ETag", `"login-a"`)
		_ = json.NewEncoder(w).Encode(map[string]any{"id": "chosen-login", "provider": "provider", "url": "https://provider.example/authorize", "expires_at": "2026-10-04T00:00:00Z", "state": "waiting", "instructions": nil, "progress": "Waiting", "accounts": []any{}, "failure": nil})
	})
	result, err := StartSignInWithID(t.Context(), conn, "chosen-login", "provider", "device", values)
	if err != nil || result.ETag != `"login-a"` || len(admitted) != 2 || admitted[0] != admitted[1] {
		t.Fatalf("login intent changed across retry: %v %#v %v", err, result, admitted)
	}
	var request map[string]any
	_ = json.Unmarshal([]byte(admitted[0]), &request)
	if request["flow"] != "device" || request["values"].(map[string]any)["secret"] != "one-time-secret" {
		t.Fatalf("advertised flow or secret omitted: %v", request)
	}
}

// The daemon cannot manufacture an invalid extension schema or result. This
// controlled peer verifies the effect is never replayed and omitted form values
// do not become unintended null writes.
