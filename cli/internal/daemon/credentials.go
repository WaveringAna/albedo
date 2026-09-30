package daemon

import (
	"context"
	"net/http"
)

// The daemon alone reads and writes creds.json. A client changes a profile's
// api key or an MCP server's secrets through these routes and only ever learns
// which secrets are saved, never what they are.

// Credentials names the saved secrets.
type Credentials struct {
	MCP map[string]MCPSecretNames `json:"mcp"`
	// Providers are the profiles with a saved api key.
	Providers []string `json:"providers"`
}

// MCPSecretNames is what an MCP server has saved, by name only.
type MCPSecretNames struct {
	Headers     []string `json:"headers"`
	Env         []string `json:"env"`
	BearerToken bool     `json:"bearerToken"`
}

// Any reports whether the server has any secret saved.
func (n MCPSecretNames) Any() bool {
	return n.BearerToken || len(n.Headers) > 0 || len(n.Env) > 0
}

// MCPSecretsPatch changes an MCP server's secrets field by field: a field left
// out keeps its value and a nil one removes it. "headers" and "env" map a name
// to its new value, or to nil to remove that one.
type MCPSecretsPatch map[string]any

// TakeMigration names the files the daemon's start moved secrets out of, only
// to the first client that asks, so the user hears about it once.
func TakeMigration(ctx context.Context, conn *Connection) ([]string, error) {
	taken, err := RequestMethod[struct {
		Moved []string `json:"moved"`
	}](ctx, conn, http.MethodPost, "/auth/credentials/migration", map[string]string{})
	return taken.Moved, err
}
