package daemon

import (
	"albedo/cli/internal/config"
	"context"
	"net/http"
	"net/url"
)

// Settings is a redacted snapshot of the daemon's shared persisted preferences.
type Settings struct {
	Profiles     config.Profiles             `json:"profiles"`
	MCP          map[string]config.MCPServer `json:"mcp"`
	Capabilities config.CapabilityPrefs      `json:"capabilities"`
	UI           UIPreferences               `json:"ui"`
	Credentials  Credentials                 `json:"credentials"`
}

type UIPreferences struct {
	Pinned   []string       `json:"pinned,omitempty"`
	Archived []string       `json:"archived,omitempty"`
	Opens    map[string]int `json:"opens,omitempty"`
	Thinking bool           `json:"thinking"`
	Tools    bool           `json:"tools"`
}

func GetSettings(ctx context.Context, conn *Connection) (Settings, error) {
	if err := CheckCapability(ctx, conn, "settings_api", "for persisted settings; upgrade the CLI and daemon together"); err != nil {
		return Settings{}, err
	}
	return authRequest[Settings](ctx, conn, http.MethodGet, "/settings", nil)
}

func ProviderProfiles(ctx context.Context, conn *Connection) (config.Profiles, error) {
	settings, err := GetSettings(ctx, conn)
	return settings.Profiles, err
}

func SaveProvider(ctx context.Context, conn *Connection, name string, profile config.Settings) error {
	_, err := authRequest[acknowledged](ctx, conn, http.MethodPut, "/settings/providers/"+url.PathEscape(name), profile)
	return err
}

func DeleteProvider(ctx context.Context, conn *Connection, name string) error {
	_, err := authRequest[acknowledged](ctx, conn, http.MethodDelete, "/settings/providers/"+url.PathEscape(name), nil)
	return err
}

func SetCapability(ctx context.Context, conn *Connection, session, kind, name, scope string, enabled *bool) error {
	_, err := authRequest[acknowledged](ctx, conn, http.MethodPost, "/sessions/"+url.PathEscape(session)+"/settings/capabilities", struct {
		Kind    string `json:"kind"`
		Name    string `json:"name"`
		Scope   string `json:"scope"`
		Enabled *bool  `json:"enabled"`
	}{kind, name, scope, enabled})
	return err
}

func SaveMCP(ctx context.Context, conn *Connection, session, name string, server *config.MCPServer, secrets MCPSecretsPatch) error {
	path := "/sessions/" + url.PathEscape(session) + "/settings/mcp/" + url.PathEscape(name)
	method := http.MethodPut
	var body any = struct {
		Server  *config.MCPServer `json:"server"`
		Secrets MCPSecretsPatch   `json:"secrets"`
	}{server, secrets}
	if server == nil {
		method, body = http.MethodDelete, nil
	}
	_, err := authRequest[acknowledged](ctx, conn, method, path, body)
	return err
}

func PatchUI(ctx context.Context, conn *Connection, patch map[string]bool) (UIPreferences, error) {
	return authRequest[UIPreferences](ctx, conn, http.MethodPatch, "/settings/ui", patch)
}

func PatchSessionUI(ctx context.Context, conn *Connection, session string, patch map[string]bool) (UIPreferences, error) {
	return authRequest[UIPreferences](ctx, conn, http.MethodPatch, "/settings/ui/sessions/"+url.PathEscape(session), patch)
}

// RecordOpen is never replayed after transport loss. The server may have already
// incremented the count even when its response did not reach us.
func RecordOpen(ctx context.Context, conn *Connection, session string) (UIPreferences, error) {
	return authRequest[UIPreferences](ctx, conn, http.MethodPost, "/settings/ui/sessions/"+url.PathEscape(session)+"/open", nil)
}
