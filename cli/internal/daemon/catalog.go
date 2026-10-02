package daemon

import (
	"context"
	"encoding/json"
	"net/http"
)

// CapabilityCatalog describes fresh discovery, independently of prepared prompts.
type CapabilityCatalog struct {
	Workspace   string             `json:"workspace"`
	Revision    string             `json:"revision"`
	Extensions  map[string]bool    `json:"extensions"`
	Diagnostics []string           `json:"diagnostics"`
	Candidates  []CatalogCandidate `json:"candidates"`
}

type CatalogCandidate struct {
	Description      *string `json:"description"`
	ResolvedSource   *string `json:"resolved_source"`
	PreferenceKey    *string `json:"preference_key"`
	Diagnostic       *string `json:"diagnostic"`
	ShadowedBy       *string `json:"shadowed_by"`
	GlobalPreference *bool   `json:"global_preference"`
	SessionOverride  *bool   `json:"session_override"`
	ID               string  `json:"id"`
	Kind             string  `json:"kind"`
	Title            string  `json:"title"`
	Source           string  `json:"source"`
	Valid            bool    `json:"valid"`
	EffectiveEnabled bool    `json:"effective_enabled"`
	Eligible         bool    `json:"eligible"`
}

type CatalogCapabilityRequest struct {
	Revision string
	ID       string
	Scope    string
	Enabled  *bool
}

type catalogCandidateWire struct {
	ID               *string         `json:"id"`
	Kind             *string         `json:"kind"`
	Title            *string         `json:"title"`
	Source           *string         `json:"source"`
	Valid            *bool           `json:"valid"`
	EffectiveEnabled *bool           `json:"effective_enabled"`
	Eligible         *bool           `json:"eligible"`
	Description      json.RawMessage `json:"description"`
	ResolvedSource   json.RawMessage `json:"resolved_source"`
	PreferenceKey    json.RawMessage `json:"preference_key"`
	Diagnostic       json.RawMessage `json:"diagnostic"`
	ShadowedBy       json.RawMessage `json:"shadowed_by"`
	GlobalPreference json.RawMessage `json:"global_preference"`
	SessionOverride  json.RawMessage `json:"session_override"`
}

func GetCapabilityCatalog(ctx context.Context, conn *Connection, session string) (CapabilityCatalog, error) {
	var result CapabilityCatalog
	err := executeRead(ctx, conn, operation{Name: "get capability catalog", Method: http.MethodGet, Path: sessionPath(session, "/catalog"), Policy: readRecovery}, func(data []byte) error {
		var wire struct {
			Workspace   *string                `json:"workspace"`
			Revision    *string                `json:"revision"`
			Extensions  map[string]*bool       `json:"extensions"`
			Diagnostics *stringCollection      `json:"diagnostics"`
			Candidates  []catalogCandidateWire `json:"candidates"`
		}
		if err := json.Unmarshal(data, &wire); err != nil {
			return err
		}
		if wire.Workspace == nil {
			return fieldError("workspace")
		}
		if wire.Revision == nil {
			return fieldError("revision")
		}
		if wire.Extensions == nil {
			return fieldError("extensions")
		}
		if wire.Diagnostics == nil {
			return fieldError("diagnostics")
		}
		if wire.Candidates == nil {
			return fieldError("candidates")
		}
		result = CapabilityCatalog{
			Workspace:   *wire.Workspace,
			Revision:    *wire.Revision,
			Extensions:  make(map[string]bool, len(wire.Extensions)),
			Diagnostics: []string(*wire.Diagnostics),
			Candidates:  make([]CatalogCandidate, 0, len(wire.Candidates)),
		}
		for name, enabled := range wire.Extensions {
			if enabled == nil {
				return fieldError("extensions." + name)
			}
			result.Extensions[name] = *enabled
		}
		for _, wire := range wire.Candidates {
			if wire.ID == nil {
				return fieldError("id")
			}
			if wire.Kind == nil {
				return fieldError("kind")
			}
			if wire.Title == nil {
				return fieldError("title")
			}
			if wire.Source == nil {
				return fieldError("source")
			}
			if wire.Valid == nil {
				return fieldError("valid")
			}
			if wire.EffectiveEnabled == nil {
				return fieldError("effective_enabled")
			}
			if wire.Eligible == nil {
				return fieldError("eligible")
			}
			candidate := CatalogCandidate{
				ID:               *wire.ID,
				Kind:             *wire.Kind,
				Title:            *wire.Title,
				Source:           *wire.Source,
				Valid:            *wire.Valid,
				EffectiveEnabled: *wire.EffectiveEnabled,
				Eligible:         *wire.Eligible,
			}
			if candidate.ID == "" {
				return fieldError("id")
			}
			if wire.Description == nil {
				return fieldError("description")
			}
			if err := json.Unmarshal(wire.Description, &candidate.Description); err != nil {
				return err
			}
			if wire.ResolvedSource == nil {
				return fieldError("resolved_source")
			}
			if err := json.Unmarshal(wire.ResolvedSource, &candidate.ResolvedSource); err != nil {
				return err
			}
			if wire.PreferenceKey == nil {
				return fieldError("preference_key")
			}
			if err := json.Unmarshal(wire.PreferenceKey, &candidate.PreferenceKey); err != nil {
				return err
			}
			if wire.Diagnostic == nil {
				return fieldError("diagnostic")
			}
			if err := json.Unmarshal(wire.Diagnostic, &candidate.Diagnostic); err != nil {
				return err
			}
			if wire.ShadowedBy == nil {
				return fieldError("shadowed_by")
			}
			if err := json.Unmarshal(wire.ShadowedBy, &candidate.ShadowedBy); err != nil {
				return err
			}
			if wire.GlobalPreference == nil {
				return fieldError("global_preference")
			}
			if err := json.Unmarshal(wire.GlobalPreference, &candidate.GlobalPreference); err != nil {
				return err
			}
			if wire.SessionOverride == nil {
				return fieldError("session_override")
			}
			if err := json.Unmarshal(wire.SessionOverride, &candidate.SessionOverride); err != nil {
				return err
			}
			result.Candidates = append(result.Candidates, candidate)
		}
		return nil
	})
	return result, err
}

func SetCatalogCapability(ctx context.Context, conn *Connection, session string, request CatalogCapabilityRequest) (ReloadResult, error) {
	return reloadSettings(ctx, conn, operation{Name: "set catalog capability", Method: http.MethodPost, Path: sessionPath(session, "/catalog"), Body: struct {
		Enabled  *bool  `json:"enabled"`
		Revision string `json:"revision"`
		ID       string `json:"id"`
		Scope    string `json:"scope"`
	}{Enabled: request.Enabled, Revision: request.Revision, ID: request.ID, Scope: request.Scope}, Policy: authRecovery})
}
