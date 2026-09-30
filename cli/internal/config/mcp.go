package config

import (
	"encoding/json"
	"errors"
	"fmt"
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
		return nil, errors.New("extensions.json is larger than 1 MiB. Reduce its size and try again.")
	}
	var root struct {
		MCP struct {
			Servers map[string]MCPServer `json:"servers"`
		} `json:"mcp"`
	}
	if err := json.Unmarshal(data, &root); err != nil {
		return nil, fmt.Errorf("invalid extensions.json: %w", err)
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
		return errors.New("Enter an MCP server name.")
	}
	return lockedUpdate(home, "extensions.lock", 50, func() error {
		path := filepath.Join(home, "extensions.json")
		data, err := os.ReadFile(path)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		root := map[string]json.RawMessage{}
		if len(data) > 0 {
			if err := json.Unmarshal(data, &root); err != nil {
				return fmt.Errorf("invalid extensions.json: %w", err)
			}
		}
		mcp := map[string]json.RawMessage{}
		if len(root["mcp"]) > 0 {
			if err := json.Unmarshal(root["mcp"], &mcp); err != nil {
				return fmt.Errorf("invalid MCP settings in extensions.json: %w", err)
			}
		}
		servers := map[string]json.RawMessage{}
		if len(mcp["servers"]) > 0 {
			if err := json.Unmarshal(mcp["servers"], &servers); err != nil {
				return fmt.Errorf("invalid MCP servers in extensions.json: %w", err)
			}
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
				if err := json.Unmarshal(servers[name], &old); err != nil {
					return fmt.Errorf("invalid MCP server %q in extensions.json: %w", name, err)
				}
				if err := json.Unmarshal(next, &patch); err != nil {
					return fmt.Errorf("decode MCP server update: %w", err)
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
