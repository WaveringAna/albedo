package config

type MCPServer struct {
	Enabled           *bool                        `json:"enabled,omitempty"`
	Headers           map[string]map[string]string `json:"headers,omitempty"`
	Env               map[string]map[string]string `json:"env,omitempty"`
	Type              string                       `json:"type"`
	URL               string                       `json:"url,omitempty"`
	Command           string                       `json:"command,omitempty"`
	CWD               string                       `json:"cwd,omitempty"`
	BearerTokenEnvVar string                       `json:"bearerTokenEnvVar,omitempty"`
	Args              []string                     `json:"args,omitempty"`
	EnabledTools      []string                     `json:"enabledTools,omitempty"`
	DisabledTools     []string                     `json:"disabledTools,omitempty"`
	StartupTimeoutMs  int                          `json:"startupTimeoutMs,omitempty"`
	CallTimeoutMs     int                          `json:"callTimeoutMs,omitempty"`
}
