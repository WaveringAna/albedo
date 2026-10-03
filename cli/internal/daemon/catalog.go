package daemon

import (
	"context"
	"net/http"
	"net/url"
)

type CapabilityCatalog struct {
	Workspace, Revision string
	Extensions          map[string]bool
	Diagnostics         []string
	Candidates          []CatalogCandidate
	Commands            []SessionCommand
	Pages               []*PageDocument
}
type CatalogCandidate struct {
	Description, ResolvedSource, PreferenceKey, Diagnostic, ShadowedBy *string
	GlobalPreference, SessionOverride                                  *bool
	ID, Kind, Title, Source                                            string
	Valid, EffectiveEnabled, Eligible, Quarantined                     bool
	Dependencies                                                       []string
	Extension                                                          *wireExtensionMetadata
}
type CatalogCapabilityRequest struct {
	Revision, ID, Kind, Scope, ETag string
	Enabled                         *bool
}

type CatalogDiscoveryError struct{ Code, Detail string }

func (e *CatalogDiscoveryError) Error() string { return e.Detail }

func GetCapabilityCatalog(ctx context.Context, conn *Connection, session string) (CapabilityCatalog, error) {
	return readCapabilityCatalog(ctx, conn, session, true)
}

func readCapabilityCatalog(ctx context.Context, conn *Connection, session string, withDiscovery bool) (CapabilityCatalog, error) {
	var result CapabilityCatalog
	result.Extensions = map[string]bool{}
	result.Candidates = []CatalogCandidate{}
	result.Commands = []SessionCommand{}
	query := url.Values{"limit": {"200"}}
	first := true
	seenCandidates, seenCommands, seenTokens := map[string]bool{}, map[string]bool{}, map[string]bool{}
	pending := []string{}
	var loadedRevision *string
	loadedSeen := false
	for {
		var catalog wireCatalog
		err := executeRead(ctx, conn, operation{Capability: "catalog", Name: "read session catalog", Method: http.MethodGet, Path: sessionPath(session, "/catalog?"+query.Encode()), Policy: readRecovery}, func(data []byte) error {
			return decodeRequired(data, &catalog, "discovery", "discovery_failure", "loaded")
		})
		if err != nil {
			return CapabilityCatalog{}, err
		}
		if catalog.Loaded.Commands == nil || (catalog.Discovery == nil) != (catalog.DiscoveryFailure != nil) {
			return CapabilityCatalog{}, fieldError("catalog")
		}
		if catalog.DiscoveryFailure != nil {
			if catalog.DiscoveryFailure.Code == "" || catalog.DiscoveryFailure.Detail == "" {
				return CapabilityCatalog{}, fieldError("catalog discovery failure")
			}
			if withDiscovery {
				return CapabilityCatalog{}, &CatalogDiscoveryError{Code: catalog.DiscoveryFailure.Code, Detail: catalog.DiscoveryFailure.Detail}
			}
		}
		if withDiscovery {
			if catalog.Discovery.Revision == "" || catalog.Discovery.Candidates == nil {
				return CapabilityCatalog{}, fieldError("catalog discovery")
			}
			if first {
				result.Workspace, result.Revision = catalog.Discovery.Workspace, catalog.Discovery.Revision
				first = false
			} else if result.Revision != catalog.Discovery.Revision {
				return CapabilityCatalog{}, &APIError{StatusCode: 409, Code: "catalog_changed", Message: "the catalog changed during paging; refresh it"}
			}
		}
		if !loadedSeen {
			loadedRevision, loadedSeen = catalog.Loaded.Revision, true
		} else if (loadedRevision == nil) != (catalog.Loaded.Revision == nil) || value(loadedRevision) != value(catalog.Loaded.Revision) {
			return CapabilityCatalog{}, fieldError("loaded catalog revision")
		}
		if withDiscovery {
			for _, candidate := range catalog.Discovery.Candidates {
				if seenCandidates[candidate.ID] {
					continue
				}
				seenCandidates[candidate.ID] = true
				description := candidate.Description
				item := CatalogCandidate{ID: candidate.ID, Kind: catalogKind(candidate.Kind), Title: candidate.Title, Source: candidate.Source, Description: &description, ResolvedSource: candidate.ResolvedSource, PreferenceKey: candidate.PreferenceKey, Diagnostic: nil, ShadowedBy: candidate.ShadowedBy, GlobalPreference: candidate.GlobalPreference, SessionOverride: candidate.SessionOverride, Valid: candidate.Valid, EffectiveEnabled: candidate.EffectiveEnabled, Eligible: candidate.Eligible, Quarantined: candidate.Quarantined, Dependencies: candidate.Dependencies, Extension: candidate.Extension}
				if candidate.Diagnostic != nil {
					detail := candidate.Diagnostic.Detail
					item.Diagnostic = &detail
				}
				if candidate.Kind == "extension" {
					result.Extensions[candidate.ID] = candidate.EffectiveEnabled
				}
				result.Candidates = append(result.Candidates, item)
			}
			for _, reason := range catalog.Discovery.Diagnostics {
				result.Diagnostics = append(result.Diagnostics, reason.Detail)
			}
		}
		for _, raw := range catalog.Loaded.Commands {
			command, err := decodeSessionCommand(raw)
			if err != nil {
				return CapabilityCatalog{}, err
			}
			if !seenCommands[command.ID] {
				seenCommands[command.ID] = true
				result.Commands = append(result.Commands, command)
			}
		}
		for _, page := range catalog.Pages {
			converted, err := pageValue(page)
			if err != nil {
				return CapabilityCatalog{}, err
			}
			result.Pages = append(result.Pages, converted)
		}
		nextPages := []*string{catalog.Loaded.Next}
		if withDiscovery {
			nextPages = append(nextPages, catalog.Discovery.Next)
		}
		for _, next := range nextPages {
			if next != nil && !seenTokens[*next] {
				seenTokens[*next] = true
				pending = append(pending, *next)
			}
		}
		if len(pending) == 0 {
			break
		}
		query.Set("next", pending[0])
		pending = pending[1:]
	}
	return result, nil
}
func SetCatalogCapability(ctx context.Context, conn *Connection, session string, request CatalogCapabilityRequest) (ReloadResult, error) {
	return setSelection(ctx, conn, session, request.Kind, request.ID, request.Revision, request.Scope, request.ETag, request.Enabled)
}

func catalogKind(kind string) string {
	switch kind {
	case "extension":
		return "extensions"
	case "skill":
		return "skills"
	case "instruction":
		return "instructions"
	}
	return kind
}
