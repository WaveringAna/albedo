package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// CapabilityPrefs holds per-item defaults and per-session overrides. An absent
// value is enabled. Keys are skill names, instruction IDs, or MCP server names.
type CapabilityPrefs struct {
	Global   map[string]map[string]bool            `json:"global,omitempty"`
	Sessions map[string]map[string]map[string]bool `json:"sessions,omitempty"`
}

func ReadCapabilityPrefs(home string) (CapabilityPrefs, error) {
	var prefs CapabilityPrefs
	data, err := os.ReadFile(filepath.Join(home, "capabilities.json"))
	if errors.Is(err, os.ErrNotExist) {
		return prefs, nil
	}
	if err != nil {
		return prefs, err
	}
	if len(data) > 1<<20 {
		return prefs, errors.New("capabilities.json exceeds 1 MiB")
	}
	if err = json.Unmarshal(data, &prefs); err != nil {
		return CapabilityPrefs{}, errors.New("invalid capabilities.json")
	}
	return prefs, nil
}

func (p CapabilityPrefs) Enabled(session, kind, name string) bool {
	if groups := p.Sessions[session]; groups != nil {
		if state, ok := groups[kind][name]; ok {
			return state
		}
	}
	if state, ok := p.Global[kind][name]; ok {
		return state
	}
	return true
}

// SetCapability persists a single selection, preserving unrelated categories.
// Session changes affect only one session; global changes become the default.
func SetCapability(home, session, kind, name string, global, enabled bool) error {
	if session == "" || name == "" || (kind != "skills" && kind != "instructions" && kind != "mcp") {
		return errors.New("invalid capability selection")
	}
	return lockedUpdate(home, "capabilities.lock", 50, func() error {
		p, err := ReadCapabilityPrefs(home)
		if err != nil {
			return err
		}
		if global {
			if p.Global == nil {
				p.Global = make(map[string]map[string]bool)
			}
			if p.Global[kind] == nil {
				p.Global[kind] = make(map[string]bool)
			}
			p.Global[kind][name] = enabled
		} else {
			if p.Sessions == nil {
				p.Sessions = make(map[string]map[string]map[string]bool)
			}
			if p.Sessions[session] == nil {
				p.Sessions[session] = make(map[string]map[string]bool)
			}
			if p.Sessions[session][kind] == nil {
				p.Sessions[session][kind] = make(map[string]bool)
			}
			p.Sessions[session][kind][name] = enabled
		}
		if err = writeJSONAtomic(home, "capabilities.json", p); err != nil {
			return fmt.Errorf("save capability: %w", err)
		}
		return nil
	})
}

// ClearCapability removes an override, restoring inheritance from the global
// setting (or the built-in enabled default). Used for rollback after reload.
func ClearCapability(home, session, kind, name string, global bool) error {
	return lockedUpdate(home, "capabilities.lock", 50, func() error {
		p, err := ReadCapabilityPrefs(home)
		if err != nil {
			return err
		}
		if global {
			delete(p.Global[kind], name)
		} else {
			delete(p.Sessions[session][kind], name)
		}
		return writeJSONAtomic(home, "capabilities.json", p)
	})
}

// MCPCredentials are deliberately separate from extension settings, which can
// be shared. No API should return the secret contents to a view or transcript.
type MCPCredentials struct {
	Servers map[string]MCPServerSecrets `json:"servers"`
}
type MCPServerSecrets struct {
	BearerToken string            `json:"bearerToken,omitempty"`
	Headers     map[string]string `json:"headers,omitempty"`
	Env         map[string]string `json:"env,omitempty"`
}

func ReadMCPCredentials(home string) (MCPCredentials, error) {
	var c MCPCredentials
	path := filepath.Join(home, "mcp-credentials.json")
	stat, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return c, nil
	}
	if err != nil {
		return c, err
	}
	if !stat.Mode().IsRegular() || stat.Mode().Perm()&0077 != 0 {
		return c, errors.New("mcp-credentials.json must be a regular 0600 file")
	}
	if stat.Size() > 1<<20 {
		return c, errors.New("mcp-credentials.json exceeds 1 MiB")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	if err = json.Unmarshal(data, &c); err != nil {
		return MCPCredentials{}, errors.New("invalid mcp-credentials.json")
	}
	return c, nil
}

func SetMCPServerSecrets(home, name string, secret MCPServerSecrets) error {
	if name == "" {
		return errors.New("missing MCP server name")
	}
	return lockedUpdate(home, "mcp-credentials.lock", 50, func() error {
		c, err := ReadMCPCredentials(home)
		if err != nil {
			return err
		}
		if c.Servers == nil {
			c.Servers = make(map[string]MCPServerSecrets)
		}
		if secret.BearerToken == "" && len(secret.Headers) == 0 && len(secret.Env) == 0 {
			delete(c.Servers, name)
		} else {
			c.Servers[name] = secret
		}
		return writeJSONAtomic(home, "mcp-credentials.json", c)
	})
}
