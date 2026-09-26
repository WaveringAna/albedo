package tui

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"testing"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
)

func TestEffortCommandUsesModelAvailableLevels(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/sessions/s1/commands" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
		}
		if body["name"] != "/effort" || body["arguments"] != nil {
			t.Errorf("unexpected request: %#v", body)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"effort": "high", "available": []string{"low", "high", "max"}}})
	}))
	defer server.Close()
	address, _ := url.Parse(server.URL)
	port, _ := strconv.Atoi(address.Port())
	session := daemon.Session{ID: "s1", Effort: "high"}
	app := NewAppModel(daemon.NewConnection(daemon.ConnectionSnapshot{Port: port, Token: "t", Version: 2}, ""), config.Profiles{}, &session, "/work", false)
	msg, ok := app.executeCommandCmd("/effort", "", 1)().(commandExecutedMsg)
	if !ok || msg.Err != nil || len(msg.Available) != 3 || msg.Available[2] != "max" || msg.SessionID != "s1" {
		t.Fatalf("unexpected response: %#v", msg)
	}
}
