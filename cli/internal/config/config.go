package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode"
)

var (
	providerNameRegex = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$`)
)

// HomeDir returns the albedo configuration directory.
func HomeDir() string {
	if env := os.Getenv("ALBEDO_HOME"); env != "" {
		abs, err := filepath.Abs(env)
		if err == nil {
			return abs
		}
		return env
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ".albedo"
	}
	return filepath.Join(home, ".albedo")
}

// Settings represents a provider configuration. Its api key lives in the
// daemon's creds.json: APIKey carries one just entered, or one a hand edit
// left in config.json, and HasKey says the daemon holds one.
type Settings struct {
	Extension string `json:"extension,omitempty"`
	BaseURL   string `json:"baseUrl,omitempty"`
	APIKey    string `json:"apiKey,omitempty"`
	HasKey    bool   `json:"-"`
	Model     string `json:"model"`
	Protocol  string `json:"protocol"`
}

func validateModel(value string) (string, error) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" || len(trimmed) > 512 {
		return "", errors.New("Model ID must be 1–512 characters and contain no control characters.")
	}
	for _, r := range trimmed {
		if r < 0x20 || r == 0x7f {
			return "", errors.New("Model ID must be 1–512 characters and contain no control characters.")
		}
	}
	return trimmed, nil
}

// Validate checks whether the Settings instance is valid.
func (s Settings) Validate() (Settings, error) {
	if s.Protocol != "responses" && s.Protocol != "chat_completions" {
		return s, errors.New("Protocol must be responses or chat_completions.")
	}

	model, err := validateModel(s.Model)
	if err != nil {
		return s, err
	}

	ext := s.Extension
	if ext == "" {
		ext = "openai"
	}

	var endpoint string
	if s.BaseURL != "" {
		endpoint, err = ValidateEndpoint(s.BaseURL)
		if err != nil {
			return s, err
		}
	}

	if ext == "openai" && endpoint == "" {
		return s, errors.New("OpenAI provider needs an API base URL.")
	}

	if strings.ContainsFunc(s.APIKey, func(r rune) bool { return unicode.IsSpace(r) || r < 0x20 || r == 0x7f }) {
		return s, errors.New("API key must not contain spaces or control characters.")
	}

	return Settings{
		Extension: ext,
		BaseURL:   endpoint,
		APIKey:    s.APIKey,
		HasKey:    s.HasKey,
		Model:     model,
		Protocol:  s.Protocol,
	}, nil
}

// ValidateProviderName validates a profile name.
func ValidateProviderName(value string) (string, error) {
	name := strings.TrimSpace(value)
	if !providerNameRegex.MatchString(name) {
		return "", errors.New("Provider name must start with a letter or number and use only letters, numbers, dots, underscores, or hyphens (1–64 characters).")
	}
	return name, nil
}

// ValidateEndpoint parses and validates an HTTP/HTTPS API endpoint without query, credentials, or fragment.
func ValidateEndpoint(value string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(value))
	if err != nil || u.Scheme == "" || u.Host == "" {
		return "", errors.New("Enter an HTTP or HTTPS API base URL.")
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return "", errors.New("Enter an HTTP or HTTPS API base URL.")
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("Use an HTTP or HTTPS API base URL without credentials, a query, or a fragment.")
	}
	res := u.String()
	for strings.HasSuffix(res, "/") {
		res = strings.TrimSuffix(res, "/")
	}
	return res, nil
}

// Profiles represents the stored provider configuration.
type Profiles struct {
	Active    string              `json:"active,omitempty"`
	Providers map[string]Settings `json:"providers"`
}

type rawConfigFile struct {
	Active    *string             `json:"active,omitempty"`
	Providers map[string]Settings `json:"providers,omitempty"`
	Extension string              `json:"extension,omitempty"`
	BaseURL   string              `json:"baseUrl,omitempty"`
	APIKey    string              `json:"apiKey,omitempty"`
	Model     string              `json:"model,omitempty"`
	Protocol  string              `json:"protocol,omitempty"`
}

// LoadProfiles reads and validates configuration from config.json in the specified directory.
func LoadProfiles(directory string) (Profiles, error) {
	configPath := filepath.Join(directory, "config.json")
	fi, err := os.Stat(configPath)
	if err != nil {
		if os.IsNotExist(err) {
			return Profiles{Providers: make(map[string]Settings)}, nil
		}
		return Profiles{}, err
	}
	if fi.Size() > 2*1024*1024 {
		return Profiles{}, fmt.Errorf("provider configuration in %s exceeds 2 MiB", configPath)
	}
	data, err := os.ReadFile(configPath)
	if err != nil {
		if os.IsNotExist(err) {
			return Profiles{Providers: make(map[string]Settings)}, nil
		}
		return Profiles{}, err
	}

	var rawMap map[string]json.RawMessage
	if err := json.Unmarshal(data, &rawMap); err != nil {
		return Profiles{}, fmt.Errorf("invalid provider configuration in %s: %w", configPath, err)
	}

	if _, hasProviders := rawMap["providers"]; !hasProviders {
		var single Settings
		if err := json.Unmarshal(data, &single); err != nil {
			return Profiles{}, fmt.Errorf("invalid provider configuration in %s: %w", configPath, err)
		}
		validated, err := single.Validate()
		if err != nil {
			return Profiles{}, fmt.Errorf("invalid provider configuration in %s: %w", configPath, err)
		}
		return Profiles{
			Active:    "default",
			Providers: map[string]Settings{"default": validated},
		}, nil
	}

	var cfg rawConfigFile
	if err := json.Unmarshal(data, &cfg); err != nil {
		return Profiles{}, fmt.Errorf("invalid provider configuration in %s: %w", configPath, err)
	}

	providers := make(map[string]Settings)
	for k, v := range cfg.Providers {
		name, err := ValidateProviderName(k)
		if err != nil {
			return Profiles{}, fmt.Errorf("invalid provider name %q in %s: %w", k, configPath, err)
		}
		validated, err := v.Validate()
		if err != nil {
			return Profiles{}, fmt.Errorf("invalid provider %q in %s: %w", name, configPath, err)
		}
		providers[name] = validated
	}

	var active string
	if cfg.Active != nil {
		active = *cfg.Active
		if _, ok := providers[active]; !ok {
			return Profiles{}, fmt.Errorf("active provider %q is not defined in %s", active, configPath)
		}
	}

	return Profiles{
		Active:    active,
		Providers: providers,
	}, nil
}

// SaveProvider stores a named provider configuration in config.json and makes
// it active. Its api key is not written: the daemon keeps keys in creds.json.
func SaveProvider(directory, name string, s Settings) error {
	validatedName, err := ValidateProviderName(name)
	if err != nil {
		return err
	}
	validatedSettings, err := s.Validate()
	if err != nil {
		return err
	}
	validatedSettings.APIKey = ""
	return updateProfiles(directory, func(profiles *Profiles) {
		profiles.Active = validatedName
		profiles.Providers[validatedName] = validatedSettings
	})
}

// RemoveProvider deletes a named provider from config.json. Removing the
// active provider hands activity to the first remaining one by name, since the
// daemon cannot start sessions without an active provider.
func RemoveProvider(directory, name string) error {
	return updateProfiles(directory, func(profiles *Profiles) {
		delete(profiles.Providers, name)
		if _, ok := profiles.Providers[profiles.Active]; ok {
			return
		}
		profiles.Active = ""
		for remaining := range profiles.Providers {
			if profiles.Active == "" || remaining < profiles.Active {
				profiles.Active = remaining
			}
		}
	})
}

// updateProfiles rewrites config.json under config.lock.
func updateProfiles(directory string, update func(*Profiles)) error {
	err := lockedUpdate(directory, "config.lock", 1, func() error {
		saved, err := LoadProfiles(directory)
		if err != nil {
			return err
		}
		if saved.Providers == nil {
			saved.Providers = make(map[string]Settings)
		}
		update(&saved)
		return writeJSONAtomic(directory, "config.json", saved)
	})
	if errors.Is(err, os.ErrExist) {
		return fmt.Errorf("another login is saving configuration; retry or remove config.lock if that process has stopped: %w", err)
	}
	return err
}
