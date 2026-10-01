package app

import (
	"context"
	"fmt"
	"maps"
	"net/http"
	"net/url"
	"slices"
	"strings"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
)

// providerModels is one configured provider and the model ids it offers.
type providerModels struct {
	provider string
	models   []string
}

// modelChoice is a model id and the provider that serves it.
type modelChoice struct {
	provider string
	model    string
}

// configuredModels lists every provider's models, the active provider first.
// A provider lists its default model first, even when its catalog cannot be
// read, as the daemon does when it resolves an agent's model.
func configuredModels(ctx context.Context, conn *daemon.Connection, profiles config.Profiles) []providerModels {
	names := slices.Sorted(maps.Keys(profiles.Providers))
	if i := slices.Index(names, profiles.Active); i > 0 {
		names = append([]string{profiles.Active}, slices.Delete(names, i, i+1)...)
	}
	listed := make([]providerModels, 0, len(names))
	for _, name := range names {
		settings := profiles.Providers[name]
		models := []string{settings.Model}
		catalog, _ := daemon.ListProfileModels(ctx, conn, settings)
		for _, model := range catalog {
			if !slices.Contains(models, model.ID) {
				models = append(models, model.ID)
			}
		}
		listed = append(listed, providerModels{name, slices.DeleteFunc(models, func(id string) bool { return id == "" })})
	}
	return listed
}

// chooseModel resolves a model the way the daemon resolves an agent's model:
// provider/model picks the provider, and a bare id comes from the active
// provider, else from the one provider that offers it. Only exact ids match.
func chooseModel(listed []providerModels, active, requested string) (modelChoice, error) {
	for _, p := range listed {
		if model, ok := strings.CutPrefix(requested, p.provider+"/"); ok {
			if !slices.Contains(p.models, model) {
				return modelChoice{}, fmt.Errorf("provider %s does not offer model %s; run albedo models to see the models you can use", p.provider, model)
			}
			return modelChoice{p.provider, model}, nil
		}
	}
	var offering []string
	for _, p := range listed {
		if slices.Contains(p.models, requested) {
			offering = append(offering, p.provider)
		}
	}
	switch {
	case len(offering) == 0:
		return modelChoice{}, fmt.Errorf("no configured provider offers model %s; run albedo models to see the models you can use", requested)
	case slices.Contains(offering, active):
		return modelChoice{active, requested}, nil
	case len(offering) == 1:
		return modelChoice{offering[0], requested}, nil
	}
	return modelChoice{}, fmt.Errorf("model %s is offered by %s; choose one with provider/model", requested, strings.Join(offering, ", "))
}

// switchModel moves an idle session to the chosen model without making it the
// default for new sessions.
func switchModel(ctx context.Context, conn *daemon.Connection, sessionID string, choice modelChoice) error {
	if err := daemon.CheckCapability(ctx, conn, "session_model", "to choose a model for an existing session"); err != nil {
		return err
	}
	path := "/sessions/" + url.PathEscape(sessionID) + "/model"
	_, err := daemon.RequestOperation[map[string]any](ctx, conn, daemon.Operation{Name: "switch model", Method: http.MethodPost, Path: path, Body: map[string]string{"model": choice.model, "provider": choice.provider}, Policy: daemon.AuthRecovery})
	return err
}

func (s *Service) Models(ctx context.Context) ([]string, error) {
	conn, err := s.Connect(ctx)
	if err != nil {
		return nil, err
	}
	profiles, err := daemon.ProviderProfiles(ctx, conn)
	if err != nil {
		return nil, err
	}
	var models []string
	for _, p := range configuredModels(ctx, conn, profiles) {
		for _, model := range p.models {
			models = append(models, p.provider+"/"+model)
		}
	}
	return models, nil
}
