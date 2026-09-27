// MCP credentials must remain private and reject insecure files or symlinks before any daemon is started.
package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestMCPCredentialsPrivateAndFailClosed(t *testing.T) {
	home := t.TempDir()
	secret := MCPServerSecrets{BearerToken: "never-log-me"}
	if err := SetMCPServerSecrets(home, "docs", secret); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(home, "mcp-credentials.json")
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("credentials mode: %v", info.Mode())
	}
	c, err := ReadMCPCredentials(home)
	if err != nil || c.Servers["docs"].BearerToken != secret.BearerToken {
		t.Fatalf("credential round-trip: %v", err)
	}
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadMCPCredentials(home); err == nil {
		t.Fatal("accepted world-readable credentials")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(home, "other"), path); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadMCPCredentials(home); err == nil {
		t.Fatal("accepted symlink credentials")
	}
}
