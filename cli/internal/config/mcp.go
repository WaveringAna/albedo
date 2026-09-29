package config

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

type MCPServer struct {
	Type              string                       `json:"type"`
	URL               string                       `json:"url,omitempty"`
	Command           string                       `json:"command,omitempty"`
	Args              []string                     `json:"args,omitempty"`
	CWD               string                       `json:"cwd,omitempty"`
	EnabledTools      []string                     `json:"enabledTools,omitempty"`
	DisabledTools     []string                     `json:"disabledTools,omitempty"`
	StartupTimeoutMs  int                          `json:"startupTimeoutMs,omitempty"`
	CallTimeoutMs     int                          `json:"callTimeoutMs,omitempty"`
	Enabled           *bool                        `json:"enabled,omitempty"`
	BearerTokenEnvVar string                       `json:"bearerTokenEnvVar,omitempty"`
	Headers           map[string]map[string]string `json:"headers,omitempty"`
	Env               map[string]map[string]string `json:"env,omitempty"`
}

func ReadMCPServers(home string) (map[string]MCPServer, error) {
	data, err := os.ReadFile(filepath.Join(home, "extensions.json"))
	if errors.Is(err, os.ErrNotExist) {
		return map[string]MCPServer{}, nil
	}
	if err != nil {
		return nil, err
	}
	if len(data) > 1<<20 {
		return nil, errors.New("extensions.json exceeds 1 MiB")
	}
	var root struct {
		MCP struct {
			Servers map[string]MCPServer `json:"servers"`
		} `json:"mcp"`
	}
	if json.Unmarshal(data, &root) != nil {
		return nil, errors.New("invalid extensions.json")
	}
	if root.MCP.Servers == nil {
		return map[string]MCPServer{}, nil
	}
	return root.MCP.Servers, nil
}

// PutMCPServer retains unrelated extension settings and server fields. The
// configuration contains no plaintext secrets; the daemon keeps those in creds.json.
func PutMCPServer(home, name string, server *MCPServer) error {
	if name == "" {
		return errors.New("missing MCP server name")
	}
	return lockedUpdate(home, "extensions.lock", 50, func() error {
		path := filepath.Join(home, "extensions.json")
		data, err := os.ReadFile(path)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		root := map[string]json.RawMessage{}
		if len(data) > 0 && json.Unmarshal(data, &root) != nil {
			return errors.New("invalid extensions.json")
		}
		mcp := map[string]json.RawMessage{}
		if len(root["mcp"]) > 0 && json.Unmarshal(root["mcp"], &mcp) != nil {
			return errors.New("invalid MCP settings")
		}
		servers := map[string]json.RawMessage{}
		if len(mcp["servers"]) > 0 && json.Unmarshal(mcp["servers"], &servers) != nil {
			return errors.New("invalid MCP servers")
		}
		if server == nil {
			delete(servers, name)
		} else {
			next, err := json.Marshal(server)
			if err != nil {
				return err
			}
			if len(servers[name]) > 0 {
				old, patch := map[string]json.RawMessage{}, map[string]json.RawMessage{}
				if json.Unmarshal(servers[name], &old) != nil || json.Unmarshal(next, &patch) != nil {
					return errors.New("invalid MCP server configuration")
				}
				for key, value := range patch {
					old[key] = value
				}
				next, err = json.Marshal(old)
				if err != nil {
					return err
				}
			}
			servers[name] = next
		}
		next, err := json.Marshal(servers)
		if err != nil {
			return err
		}
		mcp["servers"] = next
		next, err = json.Marshal(mcp)
		if err != nil {
			return err
		}
		root["mcp"] = next
		return writeJSONAtomic(home, "extensions.json", root)
	})
}
