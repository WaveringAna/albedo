package daemon

import (
	"context"
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

func GetCapabilityCatalog(ctx context.Context, conn *Connection, session string) (CapabilityCatalog, error) {
	return RequestOperation[CapabilityCatalog](ctx, conn, Operation{Name: "get capability catalog", Method: http.MethodGet, Path: sessionPath(session, "/catalog"), Policy: ReadRecovery})
}

func SetCatalogCapability(ctx context.Context, conn *Connection, session, revision, id, scope string, enabled *bool) (ReloadResult, error) {
	return reloadSettings(ctx, conn, Operation{Name: "set catalog capability", Method: http.MethodPost, Path: sessionPath(session, "/catalog"), Body: struct {
		Enabled  *bool  `json:"enabled"`
		Revision string `json:"revision"`
		ID       string `json:"id"`
		Scope    string `json:"scope"`
	}{Enabled: enabled, Revision: revision, ID: id, Scope: scope}, Policy: AuthRecovery})
}
