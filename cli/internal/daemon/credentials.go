package daemon

import (
	"encoding/json"
	"errors"
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
		fields["bearer_token"] = *patch.BearerToken
	} else if patch.RemoveBearerToken {
		fields["bearer_token"] = nil
	}
	if patch.Headers != nil {
		fields["headers"] = patch.Headers
	} else if patch.ClearHeaders {
		fields["headers"] = nil
	}
	if patch.Env != nil {
		fields["environment"] = patch.Env
	} else if patch.ClearEnv {
		fields["environment"] = nil
	}
	return json.Marshal(fields)
}
