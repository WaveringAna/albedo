package config

// CapabilityPrefs holds per-item defaults and per-session overrides. An absent
// value is enabled. Keys are skill names, instruction IDs, or MCP server names.
type CapabilityPrefs struct {
	Global   map[string]map[string]bool            `json:"global,omitempty"`
	Sessions map[string]map[string]map[string]bool `json:"sessions,omitempty"`
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
