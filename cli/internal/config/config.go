package config

import (
	"crypto/rand"
	"encoding/hex"
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

// Settings represents provider configuration for either OpenAI or Codex.
type Settings struct {
	Extension string `json:"extension,omitempty"`
	BaseURL   string `json:"baseUrl,omitempty"`
	APIKey    string `json:"apiKey,omitempty"`
	Model     string `json:"model"`
	Protocol  string `json:"protocol"`
}

func (s Settings) IsCodex() bool {
	return s.Extension == "codex"
}

func validateModel(value string) (string, error) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" || len(trimmed) > 512 {
		return "", errors.New("provider needs a model id of 1–512 characters")
	}
	for _, r := range trimmed {
		if r < 0x20 || r == 0x7f {
			return "", errors.New("provider needs a model id of 1–512 characters")
		}
	}
	return trimmed, nil
}

// Validate checks whether the Settings instance is valid.
func (s Settings) Validate() (Settings, error) {
	if s.Extension == "codex" {
		if s.Protocol != "responses" {
			return s, errors.New("codex requires the responses protocol")
		}
		model, err := validateModel(s.Model)
		if err != nil {
			return s, err
		}
		return Settings{
			Extension: "codex",
			Model:     model,
			Protocol:  "responses",
		}, nil
	}

	if s.Extension != "" && s.Extension != "openai" {
		return s, errors.New("openai provider needs an endpoint, api key, model and valid protocol")
	}

	if s.APIKey == "" {
		return s, errors.New("openai provider needs an endpoint, api key, model and valid protocol")
	}
	for _, r := range s.APIKey {
		if unicode.IsSpace(r) || r < 0x20 || r == 0x7f {
			return s, errors.New("openai provider needs an endpoint, api key, model and valid protocol")
		}
	}

	if s.Protocol != "responses" && s.Protocol != "chat_completions" {
		return s, errors.New("openai provider needs an endpoint, api key, model and valid protocol")
	}

	endpoint, err := ValidateEndpoint(s.BaseURL)
	if err != nil {
		return s, err
	}

	model, err := validateModel(s.Model)
	if err != nil {
		return s, err
	}

	return Settings{
		Extension: "openai",
		BaseURL:   endpoint,
		APIKey:    s.APIKey,
		Model:     model,
		Protocol:  s.Protocol,
	}, nil
}

// ValidateProviderName validates a profile name.
func ValidateProviderName(value string) (string, error) {
	name := strings.TrimSpace(value)
	if !providerNameRegex.MatchString(name) {
		return "", errors.New("name must be 1–64 letters, numbers, dots, underscores or hyphens")
	}
	return name, nil
}

// ValidateEndpoint parses and validates an HTTP/HTTPS API endpoint without query, credentials, or fragment.
func ValidateEndpoint(value string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(value))
	if err != nil || u.Scheme == "" || u.Host == "" {
		return "", errors.New("enter an http or https api base url")
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return "", errors.New("enter an http or https api base url")
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("use an http or https base url without credentials, query or fragment")
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
		return Profiles{}, errors.New("invalid provider configuration in config.json; repair it before logging in")
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
		return Profiles{}, errors.New("invalid provider configuration in config.json; repair it before logging in")
	}

	if _, hasProviders := rawMap["providers"]; !hasProviders {
		var single Settings
		if err := json.Unmarshal(data, &single); err != nil {
			return Profiles{}, errors.New("invalid provider configuration in config.json; repair it before logging in")
		}
		validated, err := single.Validate()
		if err != nil {
			return Profiles{}, errors.New("invalid provider configuration in config.json; repair it before logging in")
		}
		return Profiles{
			Active:    "default",
			Providers: map[string]Settings{"default": validated},
		}, nil
	}

	var cfg rawConfigFile
	if err := json.Unmarshal(data, &cfg); err != nil {
		return Profiles{}, errors.New("invalid provider configuration in config.json; repair it before logging in")
	}

	providers := make(map[string]Settings)
	for k, v := range cfg.Providers {
		name, err := ValidateProviderName(k)
		if err != nil {
			return Profiles{}, errors.New("invalid provider configuration in config.json; repair it before logging in")
		}
		validated, err := v.Validate()
		if err != nil {
			return Profiles{}, errors.New("invalid provider configuration in config.json; repair it before logging in")
		}
		providers[name] = validated
	}

	var active string
	if cfg.Active != nil {
		active = *cfg.Active
		if _, ok := providers[active]; !ok {
			return Profiles{}, errors.New("invalid provider configuration in config.json; repair it before logging in")
		}
	}

	return Profiles{
		Active:    active,
		Providers: providers,
	}, nil
}

// SaveProvider stores a named provider configuration in config.json.
func SaveProvider(directory, name string, s Settings) error {
	validatedName, err := ValidateProviderName(name)
	if err != nil {
		return err
	}
	validatedSettings, err := s.Validate()
	if err != nil {
		return err
	}

	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	_ = os.Chmod(directory, 0700)

	lockPath := filepath.Join(directory, "config.lock")
	lockFile, err := os.OpenFile(lockPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		if os.IsExist(err) {
			return errors.New("another login is saving; retry, or remove config.lock if that process has stopped")
		}
		return err
	}
	defer func() {
		_ = lockFile.Close()
		_ = os.Remove(lockPath)
	}()

	saved, err := LoadProfiles(directory)
	if err != nil {
		return err
	}

	if saved.Providers == nil {
		saved.Providers = make(map[string]Settings)
	}
	saved.Active = validatedName
	saved.Providers[validatedName] = validatedSettings

	randomBytes := make([]byte, 16)
	_, _ = rand.Read(randomBytes)
	tempPath := filepath.Join(directory, fmt.Sprintf("config.%s.tmp", hex.EncodeToString(randomBytes)))

	encoded, err := json.MarshalIndent(saved, "", "  ")
	if err != nil {
		return err
	}
	encoded = append(encoded, '\n')

	tempFile, err := os.OpenFile(tempPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	defer func() {
		_ = tempFile.Close()
		_ = os.Remove(tempPath)
	}()

	if _, err := tempFile.Write(encoded); err != nil {
		return err
	}
	if err := tempFile.Sync(); err != nil {
		return err
	}
	if err := tempFile.Close(); err != nil {
		return err
	}

	configPath := filepath.Join(directory, "config.json")
	return os.Rename(tempPath, configPath)
}
