package daemon

import (
	"albedo/cli/internal/config"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"time"
)

type ReloadResult struct {
	Reloaded string `json:"reloaded"`
	Message  string `json:"message"`
	Warning  string `json:"warning"`
}

func decodeReload(data []byte, _ int) (ReloadResult, error) {
	var wire struct {
		Reloaded *string         `json:"reloaded"`
		Message  json.RawMessage `json:"message"`
		Warning  json.RawMessage `json:"warning"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return ReloadResult{}, err
	}
	if wire.Reloaded == nil || *wire.Reloaded != "session" {
		return ReloadResult{}, fieldError("reloaded")
	}
	result := ReloadResult{Reloaded: *wire.Reloaded}
	if (wire.Message == nil) == (wire.Warning == nil) {
		return ReloadResult{}, fieldError("message")
	}
	raw, target := wire.Message, &result.Message
	field := "message"
	if raw == nil {
		raw, target, field = wire.Warning, &result.Warning, "warning"
	}
	if string(raw) == "null" {
		return ReloadResult{}, fieldError(field)
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return ReloadResult{}, &responseFieldError{field: field, cause: err}
	}
	return result, nil
}

func reloadSettings(ctx context.Context, conn *Connection, operation operation) (ReloadResult, error) {
	var result ReloadResult
	err := executeMutation(ctx, conn, operation, []int{200}, func(data []byte, status int) error {
		var err error
		result, err = decodeReload(data, status)
		return err
	})
	return result, err
}

type uiWire struct {
	Opens    *map[string]*int  `json:"opens"`
	Pinned   *stringCollection `json:"pinned"`
	Archived *stringCollection `json:"archived"`
	Thinking *bool             `json:"thinking"`
	Tools    *bool             `json:"tools"`
}

func decodeUI(data []byte, _ int) (UIPreferences, error) {
	var wire uiWire
	if err := json.Unmarshal(data, &wire); err != nil {
		return UIPreferences{}, err
	}
	return wire.value()
}

func (wire uiWire) value() (UIPreferences, error) {
	if wire.Opens == nil {
		return UIPreferences{}, fieldError("opens")
	}
	if wire.Pinned == nil {
		return UIPreferences{}, fieldError("pinned")
	}
	if wire.Archived == nil {
		return UIPreferences{}, fieldError("archived")
	}
	if wire.Thinking == nil {
		return UIPreferences{}, fieldError("thinking")
	}
	if wire.Tools == nil {
		return UIPreferences{}, fieldError("tools")
	}
	opens := make(map[string]int, len(*wire.Opens))
	for id, count := range *wire.Opens {
		if count == nil {
			return UIPreferences{}, fieldError("opens." + id)
		}
		opens[id] = *count
	}
	return UIPreferences{Opens: opens, Pinned: []string(*wire.Pinned), Archived: []string(*wire.Archived), Thinking: *wire.Thinking, Tools: *wire.Tools}, nil
}

func mutateUI(ctx context.Context, conn *Connection, operation operation) (UIPreferences, error) {
	var result UIPreferences
	err := executeMutation(ctx, conn, operation, []int{200}, func(data []byte, status int) error {
		var err error
		result, err = decodeUI(data, status)
		return err
	})
	return result, err
}

type UIPreferencesPatch struct {
	Thinking *bool `json:"thinking,omitempty"`
	Tools    *bool `json:"tools,omitempty"`
	Pinned   *bool `json:"pinned,omitempty"`
	Archived *bool `json:"archived,omitempty"`
}

// Settings is a redacted snapshot of the daemon's shared persisted preferences.
type Settings struct {
	Credentials  Credentials                 `json:"credentials"`
	Profiles     config.Profiles             `json:"profiles"`
	Capabilities config.CapabilityPrefs      `json:"capabilities"`
	MCP          map[string]config.MCPServer `json:"mcp"`
	UI           UIPreferences               `json:"ui"`
}

type UIPreferences struct {
	Opens    map[string]int `json:"opens,omitempty"`
	Pinned   []string       `json:"pinned,omitempty"`
	Archived []string       `json:"archived,omitempty"`
	Thinking bool           `json:"thinking"`
	Tools    bool           `json:"tools"`
}

func GetSettings(ctx context.Context, conn *Connection) (Settings, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if err := checkCapability(ctx, conn, "settings_api", "for persisted settings; upgrade the CLI and daemon together"); err != nil {
		return Settings{}, err
	}
	var result Settings
	err := executeRead(ctx, conn, operation{Name: "get settings", Method: http.MethodGet, Path: "/settings", Policy: readRecovery}, func(data []byte) error {
		var wire struct {
			Profiles *struct {
				Providers map[string]struct {
					config.Settings
					HasKey *bool `json:"hasKey"`
				} `json:"providers"`
				Active *string `json:"active"`
			} `json:"profiles"`
			MCP          map[string]config.MCPServer `json:"mcp"`
			Capabilities *config.CapabilityPrefs     `json:"capabilities"`
			UI           *uiWire                     `json:"ui"`
			Credentials  *struct {
				Providers *stringCollection `json:"providers"`
				MCP       map[string]struct {
					BearerToken *bool             `json:"bearerToken"`
					Headers     *stringCollection `json:"headers"`
					Env         *stringCollection `json:"env"`
				} `json:"mcp"`
			} `json:"credentials"`
		}
		if err := json.Unmarshal(data, &wire); err != nil {
			return err
		}
		if wire.Profiles == nil || wire.Profiles.Providers == nil || wire.Profiles.Active == nil {
			return fieldError("profiles")
		}
		if wire.MCP == nil {
			return fieldError("mcp")
		}
		if wire.Capabilities == nil {
			return fieldError("capabilities")
		}
		if wire.UI == nil {
			return fieldError("ui")
		}
		if wire.Credentials == nil || wire.Credentials.Providers == nil || wire.Credentials.MCP == nil {
			return fieldError("credentials")
		}
		ui, err := wire.UI.value()
		if err != nil {
			return err
		}
		profiles := config.Profiles{Active: *wire.Profiles.Active, Providers: make(map[string]config.Settings, len(wire.Profiles.Providers))}
		for name, profile := range wire.Profiles.Providers {
			if profile.HasKey == nil {
				return fieldError("profiles.providers." + name + ".hasKey")
			}
			profile.Settings.HasKey = *profile.HasKey
			profiles.Providers[name] = profile.Settings
		}
		credentials := Credentials{Providers: []string(*wire.Credentials.Providers), MCP: make(map[string]MCPSecretNames, len(wire.Credentials.MCP))}
		for name, server := range wire.Credentials.MCP {
			if server.BearerToken == nil || server.Headers == nil || server.Env == nil {
				return fieldError("credentials.mcp." + name)
			}
			credentials.MCP[name] = MCPSecretNames{BearerToken: *server.BearerToken, Headers: []string(*server.Headers), Env: []string(*server.Env)}
		}
		result = Settings{Profiles: profiles, MCP: wire.MCP, Capabilities: *wire.Capabilities, UI: ui, Credentials: credentials}
		return nil
	})
	return result, err
}

func ProviderProfiles(ctx context.Context, conn *Connection) (config.Profiles, error) {
	settings, err := GetSettings(ctx, conn)
	return settings.Profiles, err
}

func SaveProvider(ctx context.Context, conn *Connection, name string, profile config.Settings) error {
	err := acknowledge(ctx, conn, operation{Name: "save provider", Method: http.MethodPut, Path: "/settings/providers/" + url.PathEscape(name), Body: profile, Policy: authRecovery})
	return err
}

func DeleteProvider(ctx context.Context, conn *Connection, name string) error {
	err := acknowledge(ctx, conn, operation{Name: "delete provider", Method: http.MethodDelete, Path: "/settings/providers/" + url.PathEscape(name), Body: nil, Policy: authRecovery})
	return err
}

func SetCapability(ctx context.Context, conn *Connection, session string, request CapabilitySelectionRequest) (ReloadResult, error) {
	return reloadSettings(ctx, conn, operation{Name: "set capability", Method: http.MethodPost, Path: "/sessions/" + url.PathEscape(session) + "/settings/capabilities", Body: struct {
		Enabled *bool  `json:"enabled"`
		Kind    string `json:"kind"`
		Name    string `json:"name"`
		Scope   string `json:"scope"`
	}{Kind: request.Kind, Name: request.Name, Scope: request.Scope, Enabled: request.Enabled}, Policy: authRecovery})
}

func SaveMCP(ctx context.Context, conn *Connection, session string, request MCPUpdateRequest) (ReloadResult, error) {
	path := "/sessions/" + url.PathEscape(session) + "/settings/mcp/" + url.PathEscape(request.Name)
	method := http.MethodPut
	var body any = struct {
		Server  *config.MCPServer `json:"server"`
		Secrets MCPSecretsPatch   `json:"secrets"`
	}{request.Server, request.Secrets}
	if request.Server == nil {
		method, body = http.MethodDelete, nil
	}
	return reloadSettings(ctx, conn, operation{Name: "save MCP", Method: method, Path: path, Body: body, Policy: authRecovery})
}

func PatchUI(ctx context.Context, conn *Connection, patch UIPreferencesPatch) (UIPreferences, error) {
	if patch.Pinned != nil || patch.Archived != nil {
		return UIPreferences{}, errors.New("global UI preferences cannot pin or archive a session")
	}
	return mutateUI(ctx, conn, operation{Name: "patch u i", Method: http.MethodPatch, Path: "/settings/ui", Body: patch, Policy: authRecovery})
}

func PatchSessionUI(ctx context.Context, conn *Connection, session string, patch UIPreferencesPatch) (UIPreferences, error) {
	if patch.Thinking != nil || patch.Tools != nil {
		return UIPreferences{}, errors.New("session UI preferences cannot change global thinking or tools display")
	}
	return mutateUI(ctx, conn, operation{Name: "patch session u i", Method: http.MethodPatch, Path: "/settings/ui/sessions/" + url.PathEscape(session), Body: patch, Policy: authRecovery})
}

// RecordOpen is never replayed after transport loss. The server may have already
// incremented the count even when its response did not reach us.
func RecordOpen(ctx context.Context, conn *Connection, session string) (UIPreferences, error) {
	return mutateUI(ctx, conn, operation{Name: "record open", Method: http.MethodPost, Path: "/settings/ui/sessions/" + url.PathEscape(session) + "/open", Body: nil, Policy: noRecovery})
}

type CapabilitySelectionRequest struct {
	Kind    string
	Name    string
	Scope   string
	Enabled *bool
}

type MCPUpdateRequest struct {
	Name    string
	Server  *config.MCPServer
	Secrets MCPSecretsPatch
}
