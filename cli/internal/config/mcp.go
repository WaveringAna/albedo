package config

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
