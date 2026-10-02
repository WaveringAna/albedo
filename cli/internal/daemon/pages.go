package daemon

import (
	"encoding/json"
)

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

type pageRowWire struct {
	ID     *string   `json:"id"`
	Text   *string   `json:"text"`
	Badge  *string   `json:"badge"`
	Detail *string   `json:"detail"`
	Tone   *PageTone `json:"tone"`
}

type pageActionWire struct {
	Key     *string   `json:"key"`
	Label   *string   `json:"label"`
	Run     *string   `json:"run"`
	Input   *string   `json:"input"`
	Prompt  *string   `json:"prompt"`
	Value   *string   `json:"value"`
	Options []*string `json:"options"`
	Row     *bool     `json:"row"`
	Confirm *bool     `json:"confirm"`
	Prefill *bool     `json:"prefill"`
}

func decodePageRows(rows []pageRowWire) ([]PageRow, error) {
	if rows == nil {
		return nil, fieldError("rows")
	}
	result := make([]PageRow, 0, len(rows))
	for _, row := range rows {
		if row.ID == nil {
			return nil, fieldError("id")
		}
		if row.Text == nil {
			return nil, fieldError("text")
		}
		if row.Badge == nil {
			return nil, fieldError("badge")
		}
		if row.Detail == nil {
			return nil, fieldError("detail")
		}
		if row.Tone == nil {
			return nil, fieldError("tone")
		}
		switch *row.Tone {
		case TonePlain, ToneActive, ToneWarning, ToneMuted:
		default:
			return nil, fieldError("tone")
		}
		result = append(result, PageRow{ID: *row.ID, Text: *row.Text, Badge: *row.Badge, Detail: *row.Detail, Tone: *row.Tone})
	}
	return result, nil
}

func decodePageDocument(data []byte) (*PageDocument, error) {
	var envelope struct {
		Page *struct {
			Title   *string          `json:"title"`
			Summary *string          `json:"summary"`
			Empty   *string          `json:"empty"`
			Rows    []pageRowWire    `json:"rows"`
			Actions []pageActionWire `json:"actions"`
			Glance  json.RawMessage  `json:"glance"`
		} `json:"page"`
	}
	if err := json.Unmarshal(data, &envelope); err != nil {
		return nil, err
	}
	if envelope.Page == nil {
		return nil, fieldError("page")
	}
	wire := envelope.Page
	if wire.Title == nil {
		return nil, fieldError("title")
	}
	if wire.Summary == nil {
		return nil, fieldError("summary")
	}
	if wire.Empty == nil {
		return nil, fieldError("empty")
	}
	rows, err := decodePageRows(wire.Rows)
	if err != nil {
		return nil, err
	}
	if wire.Actions == nil {
		return nil, fieldError("actions")
	}
	result := &PageDocument{Title: *wire.Title, Summary: *wire.Summary, Empty: *wire.Empty, Rows: rows, Actions: make([]PageAction, 0, len(wire.Actions))}
	for _, wire := range wire.Actions {
		if wire.Key == nil || len([]rune(*wire.Key)) != 1 {
			return nil, fieldError("key")
		}
		if wire.Label == nil {
			return nil, fieldError("label")
		}
		if wire.Run == nil {
			return nil, fieldError("run")
		}
		if wire.Row == nil {
			return nil, fieldError("row")
		}
		if wire.Confirm == nil {
			return nil, fieldError("confirm")
		}
		if wire.Input == nil {
			return nil, fieldError("input")
		}
		action := PageAction{Key: *wire.Key, Label: *wire.Label, Run: *wire.Run, Row: *wire.Row, Confirm: *wire.Confirm, Input: *wire.Input}
		if wire.Prompt != nil {
			action.Prompt = *wire.Prompt
		}
		if wire.Value != nil {
			action.Value = *wire.Value
		}
		if wire.Prefill != nil {
			action.Prefill = *wire.Prefill
		}
		if wire.Options != nil {
			action.Options = make([]string, len(wire.Options))
			for index, option := range wire.Options {
				if option == nil {
					if action.Input == "choice" {
						return nil, fieldError("options")
					}
				} else {
					action.Options[index] = *option
				}
			}
		}
		switch action.Input {
		case "none":
		case "text", "secret":
			if wire.Prompt == nil {
				return nil, fieldError("prompt")
			}
			if action.Input == "text" && wire.Prefill == nil {
				return nil, fieldError("prefill")
			}
		case "value":
			if wire.Value == nil {
				return nil, fieldError("value")
			}
		case "choice":
			if len(action.Options) == 0 {
				return nil, fieldError("options")
			}
		default:
			return nil, fieldError("input")
		}
		result.Actions = append(result.Actions, action)
	}
	if wire.Glance == nil {
		return nil, fieldError("glance")
	}
	if string(wire.Glance) != "null" {
		var glance struct {
			Title *string       `json:"title"`
			Rows  []pageRowWire `json:"rows"`
		}
		if err := json.Unmarshal(wire.Glance, &glance); err != nil {
			return nil, err
		}
		if glance.Title == nil {
			return nil, fieldError("title")
		}
		rows, err := decodePageRows(glance.Rows)
		if err != nil {
			return nil, err
		}
		result.Glance = &PageGlance{Title: *glance.Title, Rows: rows}
	}
	return result, nil
}
