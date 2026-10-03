package daemon

import (
	"context"
)

type ExtensionSummary struct {
	Name, Description, Quarantined, SessionETag, GlobalETag string
	Tools, PythonModules, Requires, Plugins                 []string
	Enabled, Context, Overridden, GlobalEnabled             bool
}
type ExtensionSelectionRequest struct {
	Name, Scope, ETag string
	Enabled           *bool
}

func ListExtensions(ctx context.Context, conn *Connection, session string) ([]ExtensionSummary, error) {
	catalog, err := GetCapabilityCatalog(ctx, conn, session)
	if err != nil {
		return nil, err
	}
	configuration, err := GetSessionConfiguration(ctx, conn, session)
	if err != nil {
		return nil, err
	}
	settings, err := GetSettings(ctx, conn)
	if err != nil {
		return nil, err
	}
	result := []ExtensionSummary{}
	for _, candidate := range catalog.Candidates {
		if candidate.Kind != "extensions" {
			continue
		}
		quarantine := ""
		if candidate.Quarantined {
			quarantine = value(candidate.Diagnostic)
		}
		item := ExtensionSummary{Name: candidate.ID, Description: value(candidate.Description), Quarantined: quarantine, Enabled: candidate.EffectiveEnabled, Overridden: candidate.SessionOverride != nil, GlobalEnabled: candidate.GlobalPreference == nil || *candidate.GlobalPreference, Requires: candidate.Dependencies, SessionETag: configuration.ETag, GlobalETag: settings.ETags["extensions"]}
		if candidate.Extension != nil {
			item.Context = candidate.Extension.Context
			item.Tools = candidate.Extension.Tools
			item.PythonModules = candidate.Extension.PythonModules
			item.Plugins = candidate.Extension.Plugins
		}
		result = append(result, item)
	}
	return result, nil
}
func SelectExtension(ctx context.Context, conn *Connection, session string, request ExtensionSelectionRequest) ([]ExtensionSummary, error) {
	if request.Scope == "global" {
		_, err := patchSettingsGroup[wireExtensionSettings](ctx, conn, "extensions", request.ETag, struct {
			Defaults map[string]*bool `json:"defaults"`
		}{map[string]*bool{request.Name: request.Enabled}})
		if err != nil {
			return nil, err
		}
	} else {
		if _, err := setSelection(ctx, conn, session, "extensions", request.Name, "", request.Scope, request.ETag, request.Enabled); err != nil {
			return nil, err
		}
	}
	return ListExtensions(ctx, conn, session)
}
