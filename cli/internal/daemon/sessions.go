package daemon

type Session struct {
	ID              string `json:"id"`
	Title           string `json:"title,omitempty"`
	LastAssistantAt *int64 `json:"last_assistant_at,omitempty"`
	Workspace       string `json:"workspace"`
	Model           string `json:"model"`
	Effort          string `json:"effort,omitempty"`
	Protocol        string `json:"protocol"`
	Provider        string `json:"provider"`
}
