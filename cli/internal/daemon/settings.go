package daemon

import (
	"context"
	"errors"
	"io"
	"net/http"
	"reflect"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon/protocol"
)

type ReloadResult struct{ Reloaded, Message, Warning string }
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
		result.Profiles.Providers[name] = config.Settings{ProfileName: name, Extension: profile.Extension, BaseURL: value(profile.Endpoint), Model: profile.Model, Protocol: profile.Protocol, HasKey: profile.HasKey, Effort: profile.Effort, ImageEdge: intPointer(profile.ImageEdge), AccountID: profile.AccountID}
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

type settingsChange[T any] struct {
	Group    string `json:"group"`
	Resource struct {
		URL   string `json:"url"`
		ETag  string `json:"etag"`
		Value T      `json:"value"`
	} `json:"resource"`
	Application protocol.SettingsApplication `json:"application"`
}

func patchSettingsGroup[T any](ctx context.Context, conn *Connection, group, etag string, body any) (settingsChange[T], error) {
	var result settingsChange[T]
	headers, err := observedHeaders(etag)
	if err != nil {
		return result, err
	}
	err = executeMutation(ctx, conn, operation{Name: "edit " + group + " settings", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewPatchSettingsRequestWithBody(base, &protocol.PatchSettingsParams{Group: group, IfMatch: headers.Get("If-Match")}, "application/merge-patch+json", body)
	}, Headers: headers, Body: body, Policy: authRecovery}, []int{200}, func(data []byte, _ int) error {
		if err := decodeRequired(data, &result, "group", "resource", "application"); err != nil {
			return err
		}
		if err := validateWireJSON(data, reflect.TypeFor[settingsChange[T]]()); err != nil {
			return err
		}
		if result.Group != group || result.Resource.ETag == "" || result.Resource.URL != "/settings?group="+group {
			return fieldError("settings resource")
		}
		return nil
	})
	return result, err
}
func SaveProvider(ctx context.Context, conn *Connection, name string, profile config.Settings, etag string) error {
	return saveProvider(ctx, conn, name, profile, etag, false)
}
func SaveAndSelectProvider(ctx context.Context, conn *Connection, name string, profile config.Settings, etag string) error {
	return saveProvider(ctx, conn, name, profile, etag, true)
}
func saveProvider(ctx context.Context, conn *Connection, name string, profile config.Settings, etag string, selectDefault bool) error {
	type profilePatch struct {
		Extension string  `json:"extension"`
		Endpoint  *string `json:"endpoint"`
		Protocol  string  `json:"protocol"`
		Model     string  `json:"model"`
		Effort    *string `json:"effort"`
		ImageEdge *int    `json:"image_edge"`
		AccountID *string `json:"account_id"`
		APIKey    string  `json:"api_key,omitempty"`
	}
	var endpoint *string
	if profile.BaseURL != "" {
		endpoint = &profile.BaseURL
	}
	body := struct {
		Profiles       map[string]profilePatch `json:"profiles"`
		DefaultProfile *string                 `json:"default_profile,omitempty"`
	}{Profiles: map[string]profilePatch{name: {profile.Extension, endpoint, profile.Protocol, profile.Model, profile.Effort, profile.ImageEdge, profile.AccountID, profile.APIKey}}}
	if selectDefault {
		body.DefaultProfile = &name
	}
	_, err := patchSettingsGroup[protocol.ProviderSettings](ctx, conn, "providers", etag, body)
	return err
}
func DeleteProvider(ctx context.Context, conn *Connection, name string, profiles config.Profiles) error {
	body := map[string]any{"profiles": map[string]any{name: nil}}
	if profiles.Active == name {
		body["default_profile"] = nil
	}
	_, err := patchSettingsGroup[protocol.ProviderSettings](ctx, conn, "providers", profiles.ETag, body)
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
		_, err := patchSettingsGroup[protocol.CapabilitySettings](ctx, conn, "capabilities", etag, struct {
			SessionID string           `json:"catalog_session_id"`
			Revision  string           `json:"catalog_revision"`
			Choices   map[string]*bool `json:"choices"`
		}{session, revision, map[string]*bool{id: enabled}})
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
		definition = struct {
			Enabled           bool                         `json:"enabled"`
			Transport         string                       `json:"transport"`
			Command           *string                      `json:"command"`
			Arguments         []string                     `json:"arguments"`
			CWD               *string                      `json:"cwd"`
			URL               *string                      `json:"url"`
			Environment       map[string]map[string]string `json:"environment"`
			Headers           map[string]map[string]string `json:"headers"`
			BearerTokenEnvVar *string                      `json:"bearer_token_env_var"`
			EnabledTools      []string                     `json:"enabled_tools"`
			DisabledTools     []string                     `json:"disabled_tools"`
			StartupTimeout    int                          `json:"startup_timeout_ms,omitempty"`
			CallTimeout       int                          `json:"call_timeout_ms,omitempty"`
			Secrets           MCPSecretsPatch              `json:"secrets"`
		}{Enabled: server.Enabled == nil || *server.Enabled, Transport: server.Type, Command: optionalString(server.Command), Arguments: nonNil(server.Args), CWD: optionalString(server.CWD), URL: optionalString(server.URL), Environment: nonNilMap(server.Env), Headers: nonNilMap(server.Headers), BearerTokenEnvVar: optionalString(server.BearerTokenEnvVar), EnabledTools: nonNil(server.EnabledTools), DisabledTools: nonNil(server.DisabledTools), StartupTimeout: server.StartupTimeoutMs, CallTimeout: server.CallTimeoutMs, Secrets: secrets}
	}
	change, err := patchSettingsGroup[protocol.MCPSettings](ctx, conn, "mcp", request.ETag, struct {
		Definitions map[string]any `json:"definitions"`
	}{map[string]any{request.Name: definition}})
	return applicationResult(change.Application), err
}
func optionalString(s string) *string {
	if s == "" {
		return nil
	}
	return &s
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
	change, err := patchSettingsGroup[protocol.UISettings](ctx, conn, "ui", patch.ETag, patch)
	return UIPreferences{Thinking: change.Resource.Value.Thinking, Tools: change.Resource.Value.Tools, ETag: change.Resource.ETag}, err
}
func PatchSessionUI(ctx context.Context, conn *Connection, session string, patch UIPreferencesPatch) (UIPreferences, error) {
	if patch.Thinking != nil || patch.Tools != nil {
		return UIPreferences{}, errors.New("thinking and tools are shared preferences")
	}
	body := struct {
		Preferences struct {
			Pinned   *bool `json:"pinned,omitempty"`
			Archived *bool `json:"archived,omitempty"`
		} `json:"preferences"`
	}{}
	body.Preferences.Pinned, body.Preferences.Archived = patch.Pinned, patch.Archived
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
