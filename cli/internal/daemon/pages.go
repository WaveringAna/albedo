package daemon

type PageTone string

const (
	TonePlain   PageTone = "plain"
	ToneActive  PageTone = "active"
	ToneWarning PageTone = "warning"
	ToneMuted   PageTone = "muted"
)

type PageRow struct {
	ID     string   `json:"id"`
	Text   string   `json:"text"`
	Badge  string   `json:"badge"`
	Tone   PageTone `json:"tone"`
	Detail string   `json:"detail,omitempty"`
}

type PageAction struct {
	Key     string   `json:"key"`
	Label   string   `json:"label"`
	Run     string   `json:"run"`
	Input   string   `json:"input"` // "none" | "text" | "secret" | "choice" | "value"
	Prompt  string   `json:"prompt,omitempty"`
	Value   string   `json:"value,omitempty"`
	Options []string `json:"options,omitempty"`
	Row     bool     `json:"row"`
	Confirm bool     `json:"confirm"`
	Prefill bool     `json:"prefill,omitempty"`
}

type PageGlance struct {
	Title string    `json:"title"`
	Rows  []PageRow `json:"rows"`
}

type PageDocument struct {
	Glance  *PageGlance  `json:"glance,omitempty"`
	Title   string       `json:"title"`
	Summary string       `json:"summary"`
	Empty   string       `json:"empty"`
	Rows    []PageRow    `json:"rows"`
	Actions []PageAction `json:"actions"`
}
