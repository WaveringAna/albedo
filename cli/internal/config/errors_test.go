// Malformed local configuration must keep actionable causes without exposing
// credentials. Daemon E2E tests do not exercise the CLI's local file decoder.
package config

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadProfilesPreservesSafeDiagnostics(t *testing.T) {
	for _, tc := range []struct {
		name, data, detail string
		typeError          bool
	}{
		{"decode", `{"providers":{"work":{"apiKey":"private-credential","model":[]}}}`, "model", true},
		{"validate", `{"providers":{"work":{"apiKey":"private-credential","model":"test","protocol":"invalid"}}}`, "work", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			home := t.TempDir()
			path := filepath.Join(home, "config.json")
			if err := os.WriteFile(path, []byte(tc.data), 0600); err != nil {
				t.Fatal(err)
			}
			_, err := LoadProfiles(home)
			if err == nil || !strings.Contains(err.Error(), path) || !strings.Contains(err.Error(), tc.detail) {
				t.Fatalf("missing configuration context: %v", err)
			}
			if strings.Contains(err.Error(), "private-credential") {
				t.Fatalf("exposed credential: %v", err)
			}
			if tc.typeError {
				var cause *json.UnmarshalTypeError
				if !errors.As(err, &cause) {
					t.Fatalf("lost JSON decoding cause: %v", err)
				}
			}
		})
	}
}
