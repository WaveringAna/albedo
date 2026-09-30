package daemon

import (
	"albedo/cli/internal/config"
	"cmp"
	"context"
	"encoding/json"
	"fmt"
	"net/url"
)

// Model is one entry of a provider's model listing. Only the id is certain;
// the catalog may know the rest, and older daemons answer ids alone.
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

func (m *Model) UnmarshalJSON(data []byte) error {
	var id string
	if json.Unmarshal(data, &id) == nil {
		*m = Model{ID: id}
		return nil
	}
	type fields Model
	return json.Unmarshal(data, (*fields)(m))
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
	return Request[[]Model](ctx, conn, path, nil)
}
