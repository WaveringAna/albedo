package daemon

import (
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
	Context int      `json:"context,omitempty"`
	Output  int      `json:"output,omitempty"`
	Input   []string `json:"input,omitempty"`
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

// ListModels reads the models a provider extension lists for endpoint.
func ListModels(ctx context.Context, conn *Connection, extension, endpoint string) ([]Model, error) {
	path := fmt.Sprintf("/models/%s?endpoint=%s&details=1", url.PathEscape(extension), url.QueryEscape(endpoint))
	return Request[[]Model](ctx, conn, path, nil)
}
