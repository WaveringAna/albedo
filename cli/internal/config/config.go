// Package config defines CLI settings and validates values before they are
// submitted to the daemon. The daemon owns persistence and credentials.
package config

import (
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode"
)

var providerNameRegex = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$`)

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
// daemon's credential store. APIKey carries a newly entered draft value;
// HasKey is presence metadata returned by the daemon.
type Settings struct {
	Extension string `json:"extension,omitempty"`
	BaseURL   string `json:"baseUrl,omitempty"`
	APIKey    string `json:"apiKey,omitempty"`
	HasKey    bool   `json:"hasKey,omitempty"`
	Model     string `json:"model"`
	Protocol  string `json:"protocol"`
}

func validateModel(value string) (string, error) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" || len(trimmed) > 512 || strings.ContainsFunc(trimmed, func(r rune) bool { return r < 0x20 || r == 0x7f }) {
		return "", errors.New("model ID must be 1–512 characters and contain no control characters")
	}
	return trimmed, nil
}

// Validate checks whether the Settings instance is valid.
func (s Settings) Validate() (Settings, error) {
	if s.Protocol != "responses" && s.Protocol != "chat_completions" {
		return s, errors.New("protocol must be responses or chat_completions")
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
		return s, errors.New("OpenAI provider needs an API base URL")
	}

	if strings.ContainsFunc(s.APIKey, func(r rune) bool { return unicode.IsSpace(r) || r < 0x20 || r == 0x7f }) {
		return s, errors.New("API key must not contain spaces or control characters")
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
		return "", errors.New("provider name must start with a letter or number and use only letters, numbers, dots, underscores, or hyphens (1–64 characters)")
	}
	return name, nil
}

// ValidateEndpoint parses and validates an HTTP/HTTPS API endpoint without query, credentials, or fragment.
func ValidateEndpoint(value string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(value))
	if err != nil || u.Scheme == "" || u.Host == "" {
		return "", errors.New("enter an HTTP or HTTPS API base URL")
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return "", errors.New("enter an HTTP or HTTPS API base URL")
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("use an HTTP or HTTPS API base URL without credentials, a query, or a fragment")
	}
	return strings.TrimRight(u.String(), "/"), nil
}

// Profiles represents the stored provider configuration.
type Profiles struct {
	Active    string              `json:"active,omitempty"`
	Providers map[string]Settings `json:"providers"`
}
