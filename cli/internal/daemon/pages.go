package daemon

import (
	"bytes"
	"encoding/json"
	"fmt"
	"reflect"

	"albedo/cli/internal/daemon/protocol"
)

type PageTone string

const (
	TonePlain   PageTone = "plain"
	ToneActive  PageTone = "active"
	ToneWarning PageTone = "warning"
	ToneMuted   PageTone = "muted"
)

type PageRow struct {
	ID, Text, Badge, Detail string
	Tone                    PageTone
	wire                    protocol.PageRow
}
type PageAction struct {
	ID, Key, Label, Input, Prompt, Value, Confirmation string
	Options                                            []string
	Row, Confirm                                       bool
	Fields                                             []protocol.FormField
	Operation                                          protocol.ActionOperation
}
type PageGlance struct {
	Title string
	Rows  []PageRow
	URL   string
}
type PageDocument struct {
	Glance                *PageGlance
	Title, Summary, Empty string
	Rows                  []PageRow
	Actions               []PageAction
	Session               *Session
	read                  *pageRead
}
type pageRead struct {
	Name, Description string
	Operation         protocol.ActionOperation
	Row               *PageRow
	Form              map[string]json.RawMessage
}
type FormField = protocol.FormField

func pageRowValue(row protocol.PageRow) PageRow {
	return PageRow{ID: row.ID, Text: row.Text, Badge: value(row.Badge), Tone: PageTone(row.Tone), Detail: value(row.Detail), wire: row}
}
func glanceValue(glance protocol.Glance) *PageGlance {
	result := &PageGlance{Title: glance.Title, URL: glance.URL}
	for _, row := range glance.Rows {
		result.Rows = append(result.Rows, pageRowValue(row))
	}
	return result
}
func pageValue(wire protocol.PageDescriptor) (*PageDocument, error) {
	if wire.Title == "" || wire.Rows == nil || wire.Actions == nil {
		return nil, fieldError("page descriptor")
	}
	result := &PageDocument{Title: wire.Title, Summary: wire.Summary, Empty: wire.EmptyState, Rows: []PageRow{}, Actions: []PageAction{}}
	for _, row := range wire.Rows {
		result.Rows = append(result.Rows, pageRowValue(row))
	}
	for _, action := range wire.Actions {
		if action.ID == "" || action.Operation.PathTemplate == "" {
			return nil, fieldError("page action")
		}
		converted := PageAction{ID: action.ID, Key: value(action.KeyboardHint), Label: action.Label, Confirmation: value(action.Confirmation), Confirm: action.Confirmation != nil, Fields: action.Fields, Operation: action.Operation, Input: "none"}
		for _, bindings := range []map[string]protocol.Binding{action.Operation.Body, action.Operation.Query, action.Operation.Path, action.Operation.Headers} {
			for _, raw := range bindings {
				var binding struct {
					Source string `json:"source"`
				}
				if err := json.Unmarshal(raw, &binding); err != nil {
					return nil, fieldError("page action binding")
				}
				converted.Row = converted.Row || binding.Source == "row"
			}
		}
		for _, field := range action.Fields {
			converted.Row = converted.Row || field.DefaultBinding != nil && field.DefaultBinding.Source == "row"
		}
		if len(action.Fields) > 0 {
			setActionField(&converted, action.Fields[0])
		}
		result.Actions = append(result.Actions, converted)
	}
	if wire.Glance != nil {
		result.Glance = glanceValue(*wire.Glance)
	}
	return result, nil
}
func setActionField(action *PageAction, field protocol.FormField) {
	action.Prompt = field.Label
	action.Input = field.Type
	if field.Type == "integer" {
		action.Input = "text"
	}
	if field.Type == "boolean" {
		action.Input = "choice"
		action.Options = []string{"false", "true"}
	} else {
		action.Options = nil
		for _, choice := range field.Choices {
			action.Options = append(action.Options, choice.Label)
		}
	}
	if field.Type == "hidden" {
		action.Input = "value"
		var text string
		if json.Unmarshal(field.Default, &text) == nil {
			action.Value = text
		} else {
			action.Value = string(field.Default)
		}
	}
}
func decodePageDocument(data []byte) (*PageDocument, error) {
	envelope, err := object(data)
	if err != nil {
		return nil, err
	}
	page, ok := envelope["page"]
	if !ok {
		return nil, fieldError("page")
	}
	var document protocol.PageDescriptor
	if err := decodeRequired(page, &document, "title", "empty_state", "rows", "glance", "actions", "summary"); err != nil {
		return nil, err
	}
	return pageValue(document)
}

func readResultPage(data []byte, name, description string) (*PageDocument, error) {
	result, err := dynamicValue(data)
	if err != nil {
		return nil, err
	}
	if object, ok := result.(map[string]any); ok {
		if _, described := object["page"]; described {
			return decodePageDocument(data)
		}
	}
	formatted, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return nil, err
	}
	return &PageDocument{Title: name, Summary: description, Rows: []PageRow{{ID: "result", Text: "Result", Detail: string(formatted), Tone: TonePlain}}, Actions: []PageAction{}}, nil
}

func dynamicValue(data []byte) (any, error) {
	if !json.Valid(data) {
		return nil, fieldError("JSON value")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var result any
	err := decoder.Decode(&result)
	return result, err
}

func actionFieldValue(field protocol.FormField, text string) (json.RawMessage, error) {
	if field.Type == "hidden" {
		if err := validateFormValue(field, field.Default); err != nil {
			return nil, err
		}
		return field.Default, nil
	}
	if text == "" && field.Type != "text" && field.Type != "secret" && field.Default != nil && string(field.Default) != "null" {
		if err := validateFormValue(field, field.Default); err != nil {
			return nil, err
		}
		return field.Default, nil
	}
	if text == "" && !field.Required && field.Type != "hidden" && (field.Default == nil || string(field.Default) == "null") {
		return nil, nil
	}
	if text == "" && field.Required {
		return nil, fmt.Errorf("%s is required", field.Label)
	}
	switch field.Type {
	case "text", "secret":
		data, err := json.Marshal(text)
		return data, err
	case "choice":
		for _, choice := range field.Choices {
			if choice.Label == text || string(choice.Value) == text {
				return choice.Value, nil
			}
		}
		return nil, fmt.Errorf("choose one of the values for %s", field.Label)
	case "boolean":
		if text == "true" || text == "false" {
			return json.RawMessage(text), nil
		}
	case "integer":
		var number int64
		if json.Unmarshal([]byte(text), &number) == nil {
			if field.Minimum != nil && float64(number) < *field.Minimum || field.Maximum != nil && float64(number) > *field.Maximum {
				return nil, fmt.Errorf("%s is outside its permitted range", field.Label)
			}
			return json.RawMessage(text), nil
		}
	case "hidden":
		return field.Default, nil
	}
	return nil, fmt.Errorf("invalid %s value", field.Label)
}

// ParseActionField keeps values typed while the terminal edits their text representation.
func ParseActionField(field FormField, text string) (json.RawMessage, error) {
	return actionFieldValue(field, text)
}

func ConfigureActionField(action *PageAction, field FormField) { setActionField(action, field) }

// ResolveFormField applies only the descriptor's explicit displayed-value binding.
func ResolveFormField(field FormField, row *PageRow, session *Session) (FormField, error) {
	if field.DefaultBinding == nil {
		return field, nil
	}
	if field.DefaultBinding.Source != "row" && field.DefaultBinding.Source != "session" {
		return field, fmt.Errorf("invalid displayed default source for %s", field.Label)
	}
	var rowData, sessionData json.RawMessage
	if row != nil {
		rowData, _ = json.Marshal(row.wire)
	}
	if session != nil {
		sessionData, _ = json.Marshal(session.wire)
	}
	binding, _ := json.Marshal(field.DefaultBinding)
	resolved, err := resolveBinding(binding, rowData, nil, sessionData)
	if err != nil {
		return field, err
	}
	if err := validateFormValue(field, resolved); err != nil {
		return field, err
	}
	field.Default = resolved
	return field, nil
}
func validateFormValue(field FormField, raw json.RawMessage) error {
	switch field.Type {
	case "hidden":
		if json.Valid(raw) {
			return nil
		}
	case "text", "secret":
		var text string
		if string(raw) != "null" && json.Unmarshal(raw, &text) == nil {
			return nil
		}
	case "boolean":
		var flag bool
		if string(raw) != "null" && json.Unmarshal(raw, &flag) == nil {
			return nil
		}
	case "integer":
		var number int64
		if string(raw) != "null" && json.Unmarshal(raw, &number) == nil {
			if (field.Minimum == nil || float64(number) >= *field.Minimum) && (field.Maximum == nil || float64(number) <= *field.Maximum) {
				return nil
			}
		}
	case "choice":
		received, err := dynamicValue(raw)
		if err == nil {
			for _, choice := range field.Choices {
				candidate, err := dynamicValue(choice.Value)
				if err == nil && reflect.DeepEqual(received, candidate) {
					return nil
				}
			}
		}
	}
	return fmt.Errorf("invalid displayed default for %s", field.Label)
}

func FormChoiceDefault(field FormField) int {
	wanted, err := dynamicValue(field.Default)
	if err != nil {
		return 0
	}
	if field.Type == "boolean" {
		if wanted == true {
			return 1
		}
		return 0
	}
	for index, choice := range field.Choices {
		candidate, err := dynamicValue(choice.Value)
		if err == nil && reflect.DeepEqual(wanted, candidate) {
			return index
		}
	}
	return 0
}
