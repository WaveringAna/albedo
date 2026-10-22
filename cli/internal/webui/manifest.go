package webui

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"syscall"
	"time"

	"albedo/cli/internal/config"
)

// Manifest describes a running albedo web listener.
type Manifest struct {
	PID  int    `json:"pid"`
	Port int    `json:"port"`
	URL  string `json:"url"`
}

// ManifestPath returns the shared web listener manifest path.
func ManifestPath() string { return filepath.Join(config.HomeDir(), "web.json") }

// ReadManifest reads and decodes a web listener manifest.
func ReadManifest(path string) (Manifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Manifest{}, err
	}
	var manifest Manifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return Manifest{}, err
	}
	return manifest, nil
}

// WriteManifest atomically replaces path with a private web listener manifest.
func WriteManifest(path string, manifest Manifest) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.Marshal(manifest)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".web.json-")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}

// ManifestAlive reports whether the recorded process exists and answers its URL.
func ManifestAlive(manifest Manifest) bool {
	if manifest.PID <= 0 || manifest.URL == "" {
		return false
	}
	process, err := os.FindProcess(manifest.PID)
	if err != nil || process == nil || process.Signal(os.Signal(syscall.Signal(0))) != nil {
		return false
	}
	client := &http.Client{Timeout: 250 * time.Millisecond}
	response, err := client.Get(manifest.URL)
	if err != nil {
		return false
	}
	response.Body.Close()
	return true
}
