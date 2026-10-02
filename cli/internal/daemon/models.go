package daemon

import (
	"albedo/cli/internal/config"
	"bytes"
	"cmp"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"time"
)

// Model is one entry of a provider's model listing. Only the id is certain;
// the catalog may know the rest.
type Model struct {
	ID string `json:"id"`
	// Efforts are the reasoning levels a session accepts, lowest first.
	Efforts []string `json:"efforts,omitempty"`
	Input   []string `json:"input,omitempty"`
	Context int      `json:"context,omitempty"`
	// MaxContext is the window a raised cap gives, when the provider offers
	// more than Context; Raised says the user raised it.
	MaxContext int  `json:"maxContext,omitempty"`
	Output     int  `json:"output,omitempty"`
	Raised     bool `json:"raised,omitempty"`
}

type EffortResult struct {
	Effort    string   `json:"-"`
	Message   string   `json:"message"`
	Available []string `json:"available"`
}

type ModelSelection struct {
	Provider string `json:"provider"`
	Model    string `json:"model"`
	Protocol string `json:"protocol"`
	Effort   string `json:"effort"`
}

type ModelSelectionRequest struct {
	Model    string `json:"model"`
	Provider string `json:"provider,omitempty"`
	Effort   string `json:"effort,omitempty"`
}

// ModelChangeRequest captures a command-based model switch and its provider guard.
type ModelChangeRequest struct {
	Model           string
	Provider        string
	Effort          string
	CurrentProvider string
}

type ModelContextCapRequest struct {
	Model   string
	Enabled bool
}

// ListProfileModels reads the models a saved provider profile offers. A codex
// profile's catalog is its account's, whatever endpoint it names.
func ListProfileModels(ctx context.Context, conn *Connection, profile config.Settings) ([]Model, error) {
	extension, endpoint := cmp.Or(profile.Extension, "openai"), profile.BaseURL
	if extension == "codex" {
		endpoint = ""
	}
	return ListModels(ctx, conn, extension, endpoint)
}

// ListModels reads the models a provider extension lists for endpoint.
func ListModels(ctx context.Context, conn *Connection, extension, endpoint string) ([]Model, error) {
	path := fmt.Sprintf("/models/%s?endpoint=%s&details=1", url.PathEscape(extension), url.QueryEscape(endpoint))
	var result []Model
	err := executeRead(ctx, conn, operation{Name: "list models", Method: http.MethodGet, Path: path, Policy: readRecovery}, func(data []byte) error {
		var rows []modelWire
		if err := json.Unmarshal(data, &rows); err != nil {
			return err
		}
		if rows == nil {
			return fieldError("models")
		}
		result = make([]Model, 0, len(rows))
		for _, row := range rows {
			if row.ID == nil || *row.ID == "" {
				return fieldError("id")
			}
			result = append(result, Model{
				ID: *row.ID, Efforts: row.Efforts, Input: row.Input,
				Context: row.Context, MaxContext: row.MaxContext, Output: row.Output, Raised: row.Raised,
			})
		}
		return nil
	})
	return result, err
}

func SelectModel(ctx context.Context, conn *Connection, id string, body ModelSelectionRequest) (ModelSelection, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if err := checkCapability(ctx, conn, "session_model", "to choose a model for an existing session"); err != nil {
		return ModelSelection{}, err
	}
	var result ModelSelection
	err := executeMutation(ctx, conn, operation{Name: "select model", Method: http.MethodPost, Path: sessionPath(id, "/model"), Body: body, Policy: authRecovery}, []int{200}, func(body []byte, _ int) error {
		var err error
		result, err = decodeModelSelection(body)
		return err
	})
	return result, err
}

func ChangeModel(ctx context.Context, conn *Connection, session string, request ModelChangeRequest) (ModelSelection, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if request.Provider != "" && request.Provider != request.CurrentProvider {
		if err := checkCapability(ctx, conn, "session_provider", "to switch providers"); err != nil {
			return ModelSelection{}, err
		}
	}
	result, err := ExecuteCommand(ctx, conn, session, CommandRequest{Name: "/model", Args: &CommandArgs{Model: request.Model, Provider: request.Provider, Effort: request.Effort}})
	if err != nil {
		return ModelSelection{}, err
	}
	return *result.Model, nil
}

func SetModelContextCap(ctx context.Context, conn *Connection, session string, request ModelContextCapRequest) error {
	state := "off"
	if request.Enabled {
		state = "on"
	}
	_, err := ExecuteCommand(ctx, conn, session, CommandRequest{Name: "/raise-cap", Args: &CommandArgs{Model: request.Model, State: state}})
	return err
}

func decodeEffort(data []byte, body CommandRequest) (*EffortResult, error) {
	var wire struct {
		Effort    json.RawMessage `json:"effort"`
		Message   *string         `json:"message"`
		Available json.RawMessage `json:"available"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return nil, err
	}
	if wire.Effort == nil {
		return nil, fieldError("effort")
	}
	if wire.Message == nil {
		return nil, fieldError("message")
	}
	var effort *string
	if err := json.Unmarshal(wire.Effort, &effort); err != nil {
		return nil, &responseFieldError{field: "effort", cause: err}
	}
	result := &EffortResult{Message: *wire.Message}
	if effort != nil {
		result.Effort = *effort
	}
	if wire.Available != nil {
		var available stringCollection
		if err := json.Unmarshal(wire.Available, &available); err != nil {
			return nil, &responseFieldError{field: "available", cause: err}
		}
		result.Available = available
	} else if body.Arguments == "" && (body.Args == nil || body.Args.Level == "") {
		return nil, fieldError("available")
	}
	return result, nil
}

func decodeModelSelection(data []byte) (ModelSelection, error) {
	var wire struct {
		Provider *string         `json:"provider"`
		Model    *string         `json:"model"`
		Protocol *string         `json:"protocol"`
		Effort   json.RawMessage `json:"effort"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return ModelSelection{}, err
	}
	if wire.Provider == nil {
		return ModelSelection{}, fieldError("provider")
	}
	if wire.Model == nil {
		return ModelSelection{}, fieldError("model")
	}
	if wire.Protocol == nil {
		return ModelSelection{}, fieldError("protocol")
	}
	if wire.Effort == nil {
		return ModelSelection{}, fieldError("effort")
	}
	var effort *string
	if !bytes.Equal(bytes.TrimSpace(wire.Effort), []byte("null")) {
		if err := json.Unmarshal(wire.Effort, &effort); err != nil {
			return ModelSelection{}, &responseFieldError{field: "effort", cause: err}
		}
	}
	result := ModelSelection{Provider: *wire.Provider, Model: *wire.Model, Protocol: *wire.Protocol}
	if effort != nil {
		result.Effort = *effort
	}
	return result, nil
}

// Catalog metadata is optional; a detailed entry must name its model.
type modelWire struct {
	ID         *string  `json:"id"`
	Efforts    []string `json:"efforts"`
	Input      []string `json:"input"`
	Context    int      `json:"context"`
	MaxContext int      `json:"maxContext"`
	Output     int      `json:"output"`
	Raised     bool     `json:"raised"`
}
