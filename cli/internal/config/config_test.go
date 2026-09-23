package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestProfilesPersistenceAndMigration(t *testing.T) {
	tempDir, err := os.MkdirTemp("", "albedo-profiles-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tempDir)

	profs, err := LoadProfiles(tempDir)
	if err != nil {
		t.Fatalf("expected nil error on empty dir, got: %v", err)
	}
	if len(profs.Providers) != 0 {
		t.Fatalf("expected 0 providers, got %d", len(profs.Providers))
	}

	// Write single-provider legacy config
	fixture := `{"baseUrl": "https://example.test/v1", "apiKey": "fixture-secret", "model": "test-model", "protocol": "responses"}`
	if err := os.WriteFile(filepath.Join(tempDir, "config.json"), []byte(fixture), 0600); err != nil {
		t.Fatal(err)
	}

	profs, err = LoadProfiles(tempDir)
	if err != nil {
		t.Fatalf("failed to load legacy config: %v", err)
	}
	if profs.Providers["default"].APIKey != "fixture-secret" {
		t.Fatalf("expected fixture-secret, got: %s", profs.Providers["default"].APIKey)
	}

	// Save named provider
	localSettings := Settings{
		Extension: "openai",
		BaseURL:   "https://example.test/v1",
		APIKey:    "fixture-secret",
		Model:     "local-model",
		Protocol:  "responses",
	}
	if err := SaveProvider(tempDir, "local", localSettings); err != nil {
		t.Fatalf("failed to save provider: %v", err)
	}

	profs, err = LoadProfiles(tempDir)
	if err != nil {
		t.Fatal(err)
	}
	if profs.Active != "local" {
		t.Fatalf("expected active local, got: %s", profs.Active)
	}
	if profs.Providers["default"].Model != "test-model" {
		t.Fatalf("expected default model test-model, got: %s", profs.Providers["default"].Model)
	}
	if profs.Providers["local"].Model != "local-model" {
		t.Fatalf("expected local model local-model, got: %s", profs.Providers["local"].Model)
	}

	// Rotate key
	localSettings.APIKey = "rotated-key"
	if err := SaveProvider(tempDir, "local", localSettings); err != nil {
		t.Fatal(err)
	}
	profs, err = LoadProfiles(tempDir)
	if err != nil {
		t.Fatal(err)
	}
	if profs.Providers["local"].APIKey != "rotated-key" {
		t.Fatalf("expected rotated-key, got: %s", profs.Providers["local"].APIKey)
	}

	// Check file permissions
	dirInfo, err := os.Stat(tempDir)
	if err != nil {
		t.Fatal(err)
	}
	if perm := dirInfo.Mode().Perm(); perm != 0700 {
		t.Fatalf("expected dir mode 0700, got %o", perm)
	}

	fileInfo, err := os.Stat(filepath.Join(tempDir, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	if perm := fileInfo.Mode().Perm(); perm != 0600 {
		t.Fatalf("expected file mode 0600, got %o", perm)
	}

	// Invalid provider name
	if err := SaveProvider(tempDir, "bad name", localSettings); err == nil {
		t.Fatal("expected error on bad provider name")
	}

	// Invalid endpoint
	badEndpoint := localSettings
	badEndpoint.BaseURL = "https://secret@example.test/v1"
	if err := SaveProvider(tempDir, "bad", badEndpoint); err == nil {
		t.Fatal("expected error on credentials in endpoint")
	}

	// Corrupt config file
	brokenContent := "broken private config"
	if err := os.WriteFile(filepath.Join(tempDir, "config.json"), []byte(brokenContent), 0600); err != nil {
		t.Fatal(err)
	}
	if err := SaveProvider(tempDir, "new", localSettings); err == nil {
		t.Fatal("expected error on corrupt config.json")
	} else if !strings.Contains(err.Error(), "invalid provider configuration") {
		t.Fatalf("unexpected error message: %v", err)
	}

	currentContent, _ := os.ReadFile(filepath.Join(tempDir, "config.json"))
	if string(currentContent) != brokenContent {
		t.Fatalf("expected corrupt file to remain untouched, got: %s", string(currentContent))
	}
}

func TestRemoveProviderHandsOffActive(t *testing.T) {
	dir := t.TempDir()
	settings := Settings{BaseURL: "https://api.openai.com/v1", APIKey: "k", Model: "gpt-5", Protocol: "responses"}
	for _, name := range []string{"beta", "alpha", "gamma"} {
		if err := SaveProvider(dir, name, settings); err != nil {
			t.Fatal(err)
		}
	}

	if err := RemoveProvider(dir, "beta"); err != nil {
		t.Fatal(err)
	}
	profiles, err := LoadProfiles(dir)
	if err != nil {
		t.Fatal(err)
	}
	if profiles.Active != "gamma" || len(profiles.Providers) != 2 {
		t.Fatalf("removing an inactive provider should keep gamma active, got %+v", profiles)
	}

	if err := RemoveProvider(dir, "gamma"); err != nil {
		t.Fatal(err)
	}
	if profiles, _ = LoadProfiles(dir); profiles.Active != "alpha" {
		t.Fatalf("removing the active provider should hand off to alpha, got %q", profiles.Active)
	}

	if err := RemoveProvider(dir, "alpha"); err != nil {
		t.Fatal(err)
	}
	profiles, err = LoadProfiles(dir)
	if err != nil {
		t.Fatalf("config with no providers left should still load: %v", err)
	}
	if profiles.Active != "" || len(profiles.Providers) != 0 {
		t.Fatalf("expected no providers and no active, got %+v", profiles)
	}
}
