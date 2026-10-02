package daemon

import (
	"context"
	"encoding/json"
	"errors"
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

// MCPSecretsPatch keeps fields whose pointers or maps are nil. RemoveBearerToken
// and the Clear flags remove whole fields; a nil map entry removes that name.
type MCPSecretsPatch struct {
	BearerToken       *string
	RemoveBearerToken bool
	Headers           map[string]*string
	ClearHeaders      bool
	Env               map[string]*string
	ClearEnv          bool
}

func (patch MCPSecretsPatch) MarshalJSON() ([]byte, error) {
	if (patch.BearerToken != nil && patch.RemoveBearerToken) || (patch.Headers != nil && patch.ClearHeaders) || (patch.Env != nil && patch.ClearEnv) {
		return nil, errors.New("secret patch cannot replace and clear the same field")
	}
	fields := make(map[string]any)
	if patch.BearerToken != nil {
		fields["bearerToken"] = *patch.BearerToken
	} else if patch.RemoveBearerToken {
		fields["bearerToken"] = nil
	}
	if patch.Headers != nil {
		fields["headers"] = patch.Headers
	} else if patch.ClearHeaders {
		fields["headers"] = nil
	}
	if patch.Env != nil {
		fields["env"] = patch.Env
	} else if patch.ClearEnv {
		fields["env"] = nil
	}
	return json.Marshal(fields)
}

// TakeMigration names the files the daemon's start moved secrets out of, only
// to the first client that asks, so the user hears about it once.
func TakeMigration(ctx context.Context, conn *Connection) ([]string, error) {
	var moved []string
	err := executeMutation(ctx, conn, operation{Name: "take migration", Method: http.MethodPost, Path: "/auth/credentials/migration", Body: map[string]string{}, Policy: authRecovery}, []int{200}, func(data []byte, _ int) error {
		var wire struct {
			Moved *stringCollection `json:"moved"`
		}
		if err := json.Unmarshal(data, &wire); err != nil {
			return err
		}
		if wire.Moved == nil {
			return fieldError("moved")
		}
		moved = []string(*wire.Moved)
		return nil
	})
	return moved, err
}
