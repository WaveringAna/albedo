package daemon

import (
	"context"
	"net/http"
	"net/url"
)

// The daemon alone reads and writes creds.json. A client changes a profile's
// api key or an MCP server's secrets through these routes and only ever learns
// which secrets are saved, never what they are.

// Credentials names the saved secrets.
type Credentials struct {
	// Providers are the profiles with a saved api key.
	Providers []string                  `json:"providers"`
	MCP       map[string]MCPSecretNames `json:"mcp"`
}

// MCPSecretNames is what an MCP server has saved, by name only.
type MCPSecretNames struct {
	BearerToken bool     `json:"bearerToken"`
	Headers     []string `json:"headers"`
	Env         []string `json:"env"`
}

// Any reports whether the server has any secret saved.
func (n MCPSecretNames) Any() bool {
	return n.BearerToken || len(n.Headers) > 0 || len(n.Env) > 0
}

// MCPSecretsPatch changes an MCP server's secrets field by field: a field left
// out keeps its value and a nil one removes it. "headers" and "env" map a name
// to its new value, or to nil to remove that one.
type MCPSecretsPatch map[string]any

func SavedCredentials(ctx context.Context, conn *Connection) (Credentials, error) {
	return authRequest[Credentials](ctx, conn, http.MethodGet, "/auth/credentials", nil)
}

// TakeMigration names the files the daemon's start moved secrets out of, only
// to the first client that asks, so the user hears about it once.
func TakeMigration(ctx context.Context, conn *Connection) ([]string, error) {
	taken, err := authRequest[struct {
		Moved []string `json:"moved"`
	}](ctx, conn, http.MethodPost, "/auth/credentials/migration", map[string]string{})
	return taken.Moved, err
}

// SetProviderKey saves a profile's api key; an empty key removes it.
func SetProviderKey(ctx context.Context, conn *Connection, profile, key string) error {
	path := "/auth/credentials/providers/" + url.PathEscape(profile)
	if key == "" {
		_, err := authRequest[acknowledged](ctx, conn, http.MethodDelete, path, nil)
		return err
	}
	_, err := authRequest[acknowledged](ctx, conn, http.MethodPut, path, map[string]string{"apiKey": key})
	return err
}

// PatchMCPSecrets applies patch and returns the token UndoMCPSecrets takes to
// put back what the server held before.
func PatchMCPSecrets(ctx context.Context, conn *Connection, server string, patch MCPSecretsPatch) (string, error) {
	changed, err := authRequest[struct {
		Undo string `json:"undo"`
	}](ctx, conn, http.MethodPatch, mcpSecretsPath(server), patch)
	return changed.Undo, err
}

func UndoMCPSecrets(ctx context.Context, conn *Connection, server, token string) error {
	_, err := authRequest[acknowledged](ctx, conn, http.MethodPost, mcpSecretsPath(server)+"/undo", map[string]string{"token": token})
	return err
}

func mcpSecretsPath(server string) string {
	return "/auth/credentials/mcp/" + url.PathEscape(server)
}
