package daemon

import (
	"context"
	"errors"
	"io"
	"net/http"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon/protocol"
)

type ReloadResult struct{ Message, Warning string }
type UIPreferencesPatch struct {
	Thinking *bool  `json:"thinking,omitempty"`
	Tools    *bool  `json:"tools,omitempty"`
	Pinned   *bool  `json:"pinned,omitempty"`
	Archived *bool  `json:"archived,omitempty"`
	ETag     string `json:"-"`
}
type UIPreferences struct {
	DismissedNotices []string
	Opens            map[string]int
	Pinned, Archived []string
	Thinking, Tools  bool
	ETag             string
	SessionETags     map[string]string
}
type Settings struct {
	Credentials  Credentials
	Profiles     config.Profiles
	Capabilities config.CapabilityPrefs
	MCP          map[string]config.MCPServer
	UI           UIPreferences
	ETags        map[string]string
	Extensions   map[string]bool
	ModelCaps    map[string]bool
}

func GetSettings(ctx context.Context, conn *Connection) (Settings, error) {
	var wire protocol.Settings
	err := executeRead(ctx, conn, operation{Name: "read shared settings", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewGetSettingsRequest(base, nil)
	}, Policy: readRecovery}, func(data []byte) error {
		return decodeRequired(data, &wire)
	})
	if err != nil {
		return Settings{}, err
	}
	result := Settings{Profiles: config.Profiles{Active: value(wire.Providers.DefaultProfile), Providers: map[string]config.Settings{}, ETag: wire.GroupResources.Providers.ETag}, MCP: map[string]config.MCPServer{}, Credentials: Credentials{MCP: map[string]MCPSecretNames{}}, ETags: map[string]string{"providers": wire.GroupResources.Providers.ETag, "mcp": wire.GroupResources.MCP.ETag, "extensions": wire.GroupResources.Extensions.ETag, "capabilities": wire.GroupResources.Capabilities.ETag, "models": wire.GroupResources.Models.ETag, "ui": wire.GroupResources.UI.ETag}, Extensions: wire.Extensions.Defaults, ModelCaps: wire.Models.RaisedCaps}
	for name, profile := range wire.Providers.Profiles {
		result.Profiles.Providers[name] = config.Settings{ProfileName: name, Extension: profile.Extension, BaseURL: value(profile.Endpoint), Model: profile.Model, Protocol: profile.Protocol, HasKey: profile.HasKey, Effort: profile.Effort, ImageEdge: intPointer(profile.ImageEdge), AccountID: profile.AccountID, Project: profile.Project, Location: profile.Location}
		if profile.HasKey {
			result.Credentials.Providers = append(result.Credentials.Providers, name)
		}
	}
	for name, server := range wire.MCP.Definitions {
		enabled := server.Enabled
		result.MCP[name] = config.MCPServer{Enabled: &enabled, Type: server.Transport, URL: value(server.URL), Command: value(server.Command), Args: server.Arguments, CWD: value(server.Cwd), BearerTokenEnvVar: value(server.BearerTokenEnvVar), Env: sourceValues(server.Environment), Headers: sourceValues(server.Headers), EnabledTools: server.EnabledTools, DisabledTools: server.DisabledTools, StartupTimeoutMs: int(server.StartupTimeoutMs), CallTimeoutMs: int(server.CallTimeoutMs)}
		result.Credentials.MCP[name] = MCPSecretNames{BearerToken: server.SecretPresence.BearerToken, Headers: server.SecretPresence.Headers, Env: server.SecretPresence.Environment}
	}
	result.Capabilities = config.CapabilityPrefs{Global: map[string]map[string]bool{"mcp": {}}, Sessions: map[string]map[string]map[string]bool{}}
	for name := range result.MCP {
		if preference, ok := wire.Capabilities.Preferences["mcp:"+name]; ok {
			result.Capabilities.Global["mcp"][name] = preference
		}
	}
	result.UI = UIPreferences{DismissedNotices: wire.UI.DismissedNotices, Thinking: wire.UI.Thinking, Tools: wire.UI.Tools, ETag: wire.GroupResources.UI.ETag}
	for _, etag := range result.ETags {
		if etag == "" {
			return Settings{}, fieldError("settings group validator")
		}
	}
	return result, nil
}
func sourceValues(values map[string]protocol.ValueSource) map[string]map[string]string {
	result := map[string]map[string]string{}
	for name, value := range values {
		result[name] = map[string]string{"source": value.Source, "value": value.Value}
	}
	return result
}
func ProviderProfiles(ctx context.Context, conn *Connection) (config.Profiles, error) {
	settings, err := GetSettings(ctx, conn)
	return settings.Profiles, err
}

func patchSettingsGroup(ctx context.Context, conn *Connection, group, etag string, body any, target any) error {
	headers, err := observedHeaders(etag)
	if err != nil {
		return err
	}
	return executeMutation(ctx, conn, operation{Name: "edit " + group + " settings", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewPatchSettingsRequestWithBody(base, &protocol.PatchSettingsParams{Group: group, IfMatch: etag}, "application/merge-patch+json", body)
	}, Headers: headers, Body: body, Policy: authRecovery}, []int{200}, func(data []byte, _ int) error {
		if err := decodeRequired(data, target); err != nil {
			return err
		}
		var savedGroup, savedURL, savedETag string
		switch change := target.(type) {
		case *protocol.ProviderSettingsChange:
			savedGroup, savedURL, savedETag = change.Group, change.Resource.URL, change.Resource.ETag
		case *protocol.CapabilitySettingsChange:
			savedGroup, savedURL, savedETag = change.Group, change.Resource.URL, change.Resource.ETag
		case *protocol.MCPSettingsChange:
			savedGroup, savedURL, savedETag = change.Group, change.Resource.URL, change.Resource.ETag
		case *protocol.ExtensionSettingsChange:
			savedGroup, savedURL, savedETag = change.Group, change.Resource.URL, change.Resource.ETag
		case *protocol.ModelSettingsChange:
			savedGroup, savedURL, savedETag = change.Group, change.Resource.URL, change.Resource.ETag
		case *protocol.UISettingsChange:
			savedGroup, savedURL, savedETag = change.Group, change.Resource.URL, change.Resource.ETag
		default:
			return fieldError("settings group")
		}
		request, err := protocol.NewGetSettingsRequest("", &protocol.GetSettingsParams{Group: &group})
		if err != nil {
			return err
		}
		if savedGroup != group || savedETag == "" || savedURL != request.URL.RequestURI() {
			return fieldError("settings resource")
		}
		return nil
	})
}
func SaveProvider(ctx context.Context, conn *Connection, name string, profile config.Settings, etag string) error {
	return saveProvider(ctx, conn, name, profile, etag, false)
}
func SaveAndSelectProvider(ctx context.Context, conn *Connection, name string, profile config.Settings, etag string) error {
	return saveProvider(ctx, conn, name, profile, etag, true)
}
func saveProvider(ctx context.Context, conn *Connection, name string, profile config.Settings, etag string, selectDefault bool) error {
	// Nullable patch fields must be emitted to clear saved overrides. Generated
	// optional pointers omit nil and would preserve those overrides instead.
	profilePatch := map[string]any{
		"extension": profile.Extension, "endpoint": optionalText(profile.BaseURL),
		"protocol": profile.Protocol, "model": profile.Model, "effort": profile.Effort,
		"image_edge": profile.ImageEdge, "account_id": profile.AccountID,
		"project": profile.Project, "location": profile.Location,
	}
	if profile.APIKey != "" {
		profilePatch["api_key"] = profile.APIKey
	}
	body := map[string]any{"profiles": map[string]any{name: profilePatch}}
	if selectDefault {
		body["default_profile"] = name
	}
	var change protocol.ProviderSettingsChange
	err := patchSettingsGroup(ctx, conn, "providers", etag, body, &change)
	return err
}
func DeleteProvider(ctx context.Context, conn *Connection, name string, profiles config.Profiles) error {
	body := map[string]any{"profiles": map[string]any{name: nil}}
	if profiles.Active == name {
		body["default_profile"] = nil
	}
	var change protocol.ProviderSettingsChange
	err := patchSettingsGroup(ctx, conn, "providers", profiles.ETag, body, &change)
	return err
}

type CapabilitySelectionRequest struct {
	Kind, Name, Scope, ETag, Revision string
	Enabled                           *bool
}

func SetCapability(ctx context.Context, conn *Connection, session string, request CapabilitySelectionRequest) (ReloadResult, error) {
	return setSelection(ctx, conn, session, request.Kind, request.Name, request.Revision, request.Scope, request.ETag, request.Enabled)
}
func setSelection(ctx context.Context, conn *Connection, session, kind, id, revision, scope, etag string, enabled *bool) (ReloadResult, error) {
	if scope == "global" {
		var change protocol.CapabilitySettingsChange
		err := patchSettingsGroup(ctx, conn, "capabilities", etag, protocol.CapabilitySettingsPatch{
			CatalogSessionID: session, CatalogRevision: revision, Choices: map[string]*bool{id: enabled},
		}, &change)
		return ReloadResult{Message: "Saved the global default; reload open sessions to apply it."}, err
	}
	body := map[string]any{"selection": map[string]any{kind: map[string]*bool{id: enabled}}}
	if kind == "skills" || kind == "instructions" {
		body["catalog_revision"] = revision
	}
	_, err := patchSession(ctx, conn, session, etag, body)
	return ReloadResult{Message: "Saved the session selection; reload the session to apply it."}, err
}

type MCPUpdateRequest struct {
	Name, ETag    string
	Server        *config.MCPServer
	Secrets       MCPSecretsPatch
	StoredSecrets MCPSecretNames
}

func SaveMCP(ctx context.Context, conn *Connection, session string, request MCPUpdateRequest) (ReloadResult, error) {
	var definition any
	if request.Server != nil {
		server := request.Server
		secrets := request.Secrets
		if secrets.ClearHeaders {
			secrets.ClearHeaders = false
			secrets.Headers = map[string]*string{}
			for _, name := range request.StoredSecrets.Headers {
				secrets.Headers[name] = nil
			}
		}
		if secrets.ClearEnv {
			secrets.ClearEnv = false
			secrets.Env = map[string]*string{}
			for _, name := range request.StoredSecrets.Env {
				secrets.Env[name] = nil
			}
		}
		// These nulls clear fields when changing transports; nil optional
		// pointers in MCPDefinitionPatch would omit them.
		patch := map[string]any{
			"enabled": server.Enabled == nil || *server.Enabled, "transport": server.Type,
			"command": optionalText(server.Command), "arguments": nonNil(server.Args),
			"cwd": optionalText(server.CWD), "url": optionalText(server.URL),
			"environment": nonNilMap(server.Env), "headers": nonNilMap(server.Headers),
			"bearer_token_env_var": optionalText(server.BearerTokenEnvVar),
			"enabled_tools":        nonNil(server.EnabledTools), "disabled_tools": nonNil(server.DisabledTools),
			"secrets": secrets,
		}
		if server.StartupTimeoutMs != 0 {
			patch["startup_timeout_ms"] = server.StartupTimeoutMs
		}
		if server.CallTimeoutMs != 0 {
			patch["call_timeout_ms"] = server.CallTimeoutMs
		}
		definition = patch
	}
	var change protocol.MCPSettingsChange
	err := patchSettingsGroup(ctx, conn, "mcp", request.ETag, map[string]any{
		"definitions": map[string]any{request.Name: definition},
	}, &change)
	return applicationResult(change.Application), err
}
func nonNil[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}
func nonNilMap[K comparable, V any](m map[K]V) map[K]V {
	if m == nil {
		return map[K]V{}
	}
	return m
}
func applicationResult(application protocol.SettingsApplication) ReloadResult {
	result := ReloadResult{Message: "Saved settings."}
	if application.NeedsReloadCount > 0 {
		result.Message = "Saved settings; reload open sessions to apply them."
	}
	for _, warning := range application.Warnings {
		if result.Warning != "" {
			result.Warning += "; "
		}
		result.Warning += warning.Detail
	}
	return result
}
func PatchUI(ctx context.Context, conn *Connection, patch UIPreferencesPatch) (UIPreferences, error) {
	if patch.Pinned != nil || patch.Archived != nil {
		return UIPreferences{}, errors.New("pin and archive are session preferences")
	}
	var change protocol.UISettingsChange
	err := patchSettingsGroup(ctx, conn, "ui", patch.ETag, patch, &change)
	return UIPreferences{Thinking: change.Resource.Value.Thinking, Tools: change.Resource.Value.Tools, ETag: change.Resource.ETag}, err
}

// PatchSessionUI pins or archives one session. Session lists carry no ETag,
// so a caller without one has the session's current ETag read first.
func PatchSessionUI(ctx context.Context, conn *Connection, session string, patch UIPreferencesPatch) (UIPreferences, error) {
	if patch.Thinking != nil || patch.Tools != nil {
		return UIPreferences{}, errors.New("thinking and tools are shared preferences")
	}
	if patch.ETag == "" {
		current, err := GetSessionConfiguration(ctx, conn, session)
		if err != nil {
			return UIPreferences{}, err
		}
		patch.ETag = current.ETag
	}
	body := protocol.SessionPatch{Preferences: &protocol.PreferencePatch{Pinned: patch.Pinned, Archived: patch.Archived}}
	updated, err := patchSession(ctx, conn, session, patch.ETag, body)
	prefs := UIPreferences{SessionETags: map[string]string{session: updated.ETag}}
	if updated.Pinned {
		prefs.Pinned = []string{session}
	}
	if updated.Archived {
		prefs.Archived = []string{session}
	}
	return prefs, err
}
func RecordOpen(ctx context.Context, conn *Connection, session string) (UIPreferences, error) {
	id, err := operationID()
	if err != nil {
		return UIPreferences{}, err
	}
	var visit protocol.Visit
	err = executeMutation(ctx, conn, operation{Name: "record session visit", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewRecordVisitRequestWithBody(base, session, id, "application/json", body)
	}, Body: struct{}{}, Policy: noRecovery}, []int{201, 200}, func(data []byte, _ int) error {
		if err := decodeRequired(data, &visit); err != nil {
			return err
		}
		if visit.VisitID != id || visit.SessionID != session {
			return fieldError("visit identity")
		}
		return nil
	})
	return UIPreferences{Opens: map[string]int{session: int(visit.Opens)}}, err
}
