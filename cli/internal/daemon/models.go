package daemon

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon/protocol"
)

type Model struct {
	ID, Label, CapKey           string
	Efforts, Input              []string
	Context, MaxContext, Output int
	Raised                      bool
}
type EffortResult struct {
	Effort, Message, ETag string
	Available             []string
}
type ModelSelection struct{ Provider, Model, Protocol, Effort, ETag, DefaultETag, ModelsETag string }
type ModelSelectionRequest struct{ Model, Provider, Effort, ETag string }
type ModelChangeRequest struct {
	Model, Provider, Effort, CurrentProvider, ETag, DefaultETag string
	MakeDefault                                                 bool
}
type ModelContextCapRequest struct {
	CapKey, ETag string
	Enabled      bool
}

func ListProfileModels(ctx context.Context, conn *Connection, profile config.Settings) ([]Model, error) {
	if profile.ProfileName != "" {
		return listModels(ctx, conn, protocol.ListModelsParams{ProviderProfile: &profile.ProfileName})
	}
	return ListModels(ctx, conn, profile.Extension, profile.BaseURL)
}
func ListModels(ctx context.Context, conn *Connection, provider, endpoint string) ([]Model, error) {
	params := protocol.ListModelsParams{Provider: &provider}
	if endpoint != "" {
		params.Endpoint = &endpoint
	}
	return listModels(ctx, conn, params)
}
func listModels(ctx context.Context, conn *Connection, params protocol.ListModelsParams) ([]Model, error) {
	result := []Model{}
	params.Limit = new(int64(200))
	err := walkPages(func(next *string) (protocol.ModelPage, *string, error) {
		params.Next = next
		var page protocol.ModelPage
		pageErr := executeRead(ctx, conn, operation{Name: "list models", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
			return protocol.NewListModelsRequest(base, &params)
		}, Policy: readRecovery}, func(data []byte) error { return decodeRequired(data, &page) })
		return page, page.Next, pageErr
	}, func(page protocol.ModelPage) error {
		if page.Items == nil {
			return fieldError("models")
		}
		for _, row := range page.Items {
			if row.ID == "" || row.CapKey == "" || row.Efforts == nil {
				return fieldError("model")
			}
			model := Model{ID: row.ID, Label: row.Label, CapKey: row.CapKey, Input: row.InputModalities, Context: int(value(row.DefaultContextTokens)), MaxContext: int(value(row.MaxContextTokens)), Output: int(value(row.MaxOutputTokens)), Raised: row.Raised}
			for _, effort := range row.Efforts {
				model.Efforts = append(model.Efforts, effort.ID)
			}
			result = append(result, model)
		}
		return nil
	}, "model page cursor")
	if err != nil {
		return nil, err
	}
	return result, nil
}

func SelectModel(ctx context.Context, conn *Connection, id string, request ModelSelectionRequest) (ModelSelection, error) {
	body := map[string]any{"model": request.Model}
	if request.Provider != "" {
		body["provider_profile"] = request.Provider
	}
	if request.Effort != "" {
		body["effort"] = request.Effort
	}
	session, err := patchSession(ctx, conn, id, request.ETag, body)
	return ModelSelection{Provider: session.Provider, Model: session.Model, Protocol: session.Protocol, Effort: session.Effort, ETag: session.ETag}, err
}
func ChangeModel(ctx context.Context, conn *Connection, id string, request ModelChangeRequest) (ModelSelection, error) {
	if request.MakeDefault && request.DefaultETag == "" {
		return ModelSelection{}, fieldError("provider settings validator")
	}
	selection, err := SelectModel(ctx, conn, id, ModelSelectionRequest{Model: request.Model, Provider: request.Provider, Effort: request.Effort, ETag: request.ETag})
	if err != nil {
		return selection, err
	}
	if request.MakeDefault {
		var change protocol.ProviderSettingsChange
		saveErr := patchSettingsGroup(ctx, conn, "providers", request.DefaultETag, map[string]any{"default_profile": selection.Provider, "profiles": map[string]any{selection.Provider: map[string]any{"model": selection.Model, "effort": optionalText(selection.Effort)}}}, &change)
		selection.DefaultETag = change.Resource.ETag
		if saveErr != nil {
			return selection, fmt.Errorf("switched session; saving the default model: %w", saveErr)
		}
	}
	return selection, nil
}
func SetModelContextCap(ctx context.Context, conn *Connection, request ModelContextCapRequest) (string, error) {
	if request.CapKey == "" {
		return "", fieldError("model cap key")
	}
	var change protocol.ModelSettingsChange
	err := patchSettingsGroup(ctx, conn, "models", request.ETag, map[string]any{"raised_caps": map[string]bool{request.CapKey: request.Enabled}}, &change)
	return change.Resource.ETag, err
}
func ReadEffort(ctx context.Context, conn *Connection, session Session) (EffortResult, error) {
	params := protocol.ListModelsParams{Model: &session.Model}
	if session.Provider != "" {
		params.ProviderProfile = &session.Provider
	}
	models, err := listModels(ctx, conn, params)
	if err != nil {
		return EffortResult{}, err
	}
	for _, model := range models {
		if model.ID == session.Model {
			return EffortResult{Effort: session.Effort, Available: model.Efforts}, nil
		}
	}
	return EffortResult{}, fmt.Errorf("model %q has no metadata", session.Model)
}

// SelectEffort clears the preference when effort is empty.
func SelectEffort(ctx context.Context, conn *Connection, session Session, effort string) (EffortResult, error) {
	result, err := patchSession(ctx, conn, session.ID, session.ETag, map[string]any{"effort": optionalText(effort)})
	return EffortResult{Effort: result.Effort, Message: "Effort saved.", ETag: result.ETag}, err
}

// ResolveSessionModel keeps a manual ID in the observed session profile, or
// selects an explicitly named configured profile. The daemon validates the ID
// and computes the available reasoning efforts.
func ResolveSessionModel(profiles config.Profiles, requested string) (string, string, error) {
	if strings.TrimSpace(requested) == "" {
		return "", "", fmt.Errorf("enter a model ID")
	}
	for name := range profiles.Providers {
		if model, explicit := strings.CutPrefix(requested, name+"/"); explicit {
			if model == "" {
				return "", "", fmt.Errorf("enter a model ID after %s/", name)
			}
			return name, model, nil
		}
	}
	if _, configured := profiles.Providers[profiles.Active]; !configured {
		return "", "", fmt.Errorf("the session's provider is not configured; run /login")
	}
	return profiles.Active, requested, nil
}
