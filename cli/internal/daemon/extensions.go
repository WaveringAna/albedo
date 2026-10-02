package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
)

type ExtensionSummary struct {
	Name          string   `json:"name"`
	Description   string   `json:"description"`
	Quarantined   string   `json:"quarantined"`
	Tools         []string `json:"tools"`
	PythonModules []string `json:"python_modules"`
	Requires      []string `json:"requires"`
	Plugins       []string `json:"plugins"`
	Enabled       bool     `json:"enabled"`
	Context       bool     `json:"context"`
	Overridden    bool     `json:"overridden"`
	GlobalEnabled bool     `json:"global_enabled"`
}

type ExtensionSelectionRequest struct {
	Name    string `json:"name"`
	Scope   string `json:"scope,omitempty"`
	Enabled *bool  `json:"enabled,omitempty"`
}

func SelectExtension(ctx context.Context, conn *Connection, id string, body ExtensionSelectionRequest) ([]ExtensionSummary, error) {
	var result []ExtensionSummary
	err := executeMutation(ctx, conn, operation{Name: "select extension", Method: http.MethodPost, Path: sessionPath(id, "/extensions"), Body: body, Policy: authRecovery}, []int{200}, func(body []byte, _ int) error {
		var err error
		result, err = decodeExtensions(body)
		return err
	})
	return result, err
}

func ListExtensions(ctx context.Context, conn *Connection, session string) ([]ExtensionSummary, error) {
	var result []ExtensionSummary
	err := executeRead(ctx, conn, operation{Name: "list extensions", Method: http.MethodGet, Path: sessionPath(session, "/extensions"), Policy: readRecovery}, func(data []byte) error {
		var err error
		result, err = decodeExtensions(data)
		return err
	})
	return result, err
}

func decodeExtensions(data []byte) ([]ExtensionSummary, error) {
	type extensionWire struct {
		Name          *string          `json:"name"`
		Description   *string          `json:"description"`
		Enabled       *bool            `json:"enabled"`
		Context       *bool            `json:"context"`
		Overridden    *bool            `json:"overridden"`
		GlobalEnabled *bool            `json:"global_enabled"`
		Tools         stringCollection `json:"tools"`
		PythonModules stringCollection `json:"python_modules"`
		Requires      stringCollection `json:"requires"`
		Plugins       stringCollection `json:"plugins"`
		Quarantined   json.RawMessage  `json:"quarantined"`
	}
	var wire []extensionWire
	if err := json.Unmarshal(data, &wire); err != nil {
		return nil, err
	}
	if wire == nil {
		return nil, errors.New("expected an array")
	}
	summaries := make([]ExtensionSummary, 0, len(wire))
	for i, item := range wire {
		missing := ""
		switch {
		case item.Name == nil:
			missing = "name"
		case item.Description == nil:
			missing = "description"
		case item.Tools == nil:
			missing = "tools"
		case item.PythonModules == nil:
			missing = "python_modules"
		case item.Requires == nil:
			missing = "requires"
		case item.Plugins == nil:
			missing = "plugins"
		case item.Enabled == nil:
			missing = "enabled"
		case item.Context == nil:
			missing = "context"
		case item.Overridden == nil:
			missing = "overridden"
		case item.GlobalEnabled == nil:
			missing = "global_enabled"
		case item.Quarantined == nil:
			missing = "quarantined"
		}
		if missing != "" {
			return nil, fieldError(fmt.Sprintf("extensions[%d].%s", i, missing))
		}
		var quarantine *string
		if !bytes.Equal(bytes.TrimSpace(item.Quarantined), []byte("null")) {
			if err := json.Unmarshal(item.Quarantined, &quarantine); err != nil {
				return nil, &responseFieldError{field: fmt.Sprintf("extensions[%d].quarantined", i), cause: err}
			}
		}
		summary := ExtensionSummary{Name: *item.Name, Description: *item.Description, Tools: []string(item.Tools), PythonModules: []string(item.PythonModules), Requires: []string(item.Requires), Plugins: []string(item.Plugins), Enabled: *item.Enabled, Context: *item.Context, Overridden: *item.Overridden, GlobalEnabled: *item.GlobalEnabled}
		if quarantine != nil {
			summary.Quarantined = *quarantine
		}
		summaries = append(summaries, summary)
	}
	return summaries, nil
}
