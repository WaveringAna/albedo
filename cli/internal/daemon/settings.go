package daemon

import (
	"albedo/cli/internal/config"
	"context"
	"net/http"
	"net/url"
)

// Settings is a redacted snapshot of the daemon's shared persisted preferences.
type Settings struct {
	Credentials  Credentials                 `json:"credentials"`
	Profiles     config.Profiles             `json:"profiles"`
	Capabilities config.CapabilityPrefs      `json:"capabilities"`
	MCP          map[string]config.MCPServer `json:"mcp"`
	UI           UIPreferences               `json:"ui"`
}

type UIPreferences struct {
	Opens    map[string]int `json:"opens,omitempty"`
	Pinned   []string       `json:"pinned,omitempty"`
	Archived []string       `json:"archived,omitempty"`
	Thinking bool           `json:"thinking"`
	Tools    bool           `json:"tools"`
}

func GetSettings(ctx context.Context, conn *Connection) (Settings, error) {
	if err := CheckCapability(ctx, conn, "settings_api", "for persisted settings; upgrade the CLI and daemon together"); err != nil {
		return Settings{}, err
	}
	return RequestOperation[Settings](ctx, conn, Operation{Name: "get settings", Method: http.MethodGet, Path: "/settings", Body: nil, Policy: ReadRecovery})
}

func ProviderProfiles(ctx context.Context, conn *Connection) (config.Profiles, error) {
	settings, err := GetSettings(ctx, conn)
	return settings.Profiles, err
}

func SaveProvider(ctx context.Context, conn *Connection, name string, profile config.Settings) error {
	err := acknowledge(ctx, conn, Operation{Name: "save provider", Method: http.MethodPut, Path: "/settings/providers/" + url.PathEscape(name), Body: profile, Policy: AuthRecovery})
	return err
}

func DeleteProvider(ctx context.Context, conn *Connection, name string) error {
	err := acknowledge(ctx, conn, Operation{Name: "delete provider", Method: http.MethodDelete, Path: "/settings/providers/" + url.PathEscape(name), Body: nil, Policy: AuthRecovery})
	return err
}

func SetCapability(ctx context.Context, conn *Connection, session, kind, name, scope string, enabled *bool) (ReloadResult, error) {
	return reloadSettings(ctx, conn, Operation{Name: "set capability", Method: http.MethodPost, Path: "/sessions/" + url.PathEscape(session) + "/settings/capabilities", Body: struct {
		Enabled *bool  `json:"enabled"`
		Kind    string `json:"kind"`
		Name    string `json:"name"`
		Scope   string `json:"scope"`
	}{Kind: kind, Name: name, Scope: scope, Enabled: enabled}, Policy: AuthRecovery})
}

func SaveMCP(ctx context.Context, conn *Connection, session, name string, server *config.MCPServer, secrets MCPSecretsPatch) (ReloadResult, error) {
	path := "/sessions/" + url.PathEscape(session) + "/settings/mcp/" + url.PathEscape(name)
	method := http.MethodPut
	var body any = struct {
		Server  *config.MCPServer `json:"server"`
		Secrets MCPSecretsPatch   `json:"secrets"`
	}{server, secrets}
	if server == nil {
		method, body = http.MethodDelete, nil
	}
	return reloadSettings(ctx, conn, Operation{Name: "save MCP", Method: method, Path: path, Body: body, Policy: AuthRecovery})
}

func PatchUI(ctx context.Context, conn *Connection, patch map[string]bool) (UIPreferences, error) {
	return mutateUI(ctx, conn, Operation{Name: "patch u i", Method: http.MethodPatch, Path: "/settings/ui", Body: patch, Policy: AuthRecovery})
}

func PatchSessionUI(ctx context.Context, conn *Connection, session string, patch map[string]bool) (UIPreferences, error) {
	return mutateUI(ctx, conn, Operation{Name: "patch session u i", Method: http.MethodPatch, Path: "/settings/ui/sessions/" + url.PathEscape(session), Body: patch, Policy: AuthRecovery})
}

// RecordOpen is never replayed after transport loss. The server may have already
// incremented the count even when its response did not reach us.
func RecordOpen(ctx context.Context, conn *Connection, session string) (UIPreferences, error) {
	return mutateUI(ctx, conn, Operation{Name: "record open", Method: http.MethodPost, Path: "/settings/ui/sessions/" + url.PathEscape(session) + "/open", Body: nil, Policy: NoRecovery})
}
