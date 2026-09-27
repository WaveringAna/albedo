// Page secret actions must mask typed input with EchoPassword and never leak plaintext in views.
// Echo masking and view rendering live purely inside Bubble Tea models;
// E2E lacks a PTY harness to observe unsubmitted keystroke echo.
package tui

import (
	"strings"
	"testing"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
)

func TestPageSecretInputIsMasked(t *testing.T) {
	doc, err := parsePageDocument(map[string]any{"page": map[string]any{
		"title": "webhooks", "actions": []any{map[string]any{
			"key": "k", "label": "rotate", "run": "rotate_with_secret", "input": "secret", "prompt": "replacement",
		}},
	}})
	if err != nil {
		t.Fatal(err)
	}
	m := NewPageViewModel(nil, "session", "/webhooks")
	m.Doc = doc
	m.Busy = false
	m.SetSize(80, 24)
	m, _ = m.Update(tea.KeyPressMsg{Code: 'k', Text: "k"})
	if m.Mode != modeText || m.TextInput.EchoMode != textinput.EchoPassword {
		t.Fatalf("secret action should mask input: %+v", m)
	}
	m.TextInput.SetValue("sensitive-signing-key")
	if strings.Contains(m.View(), "sensitive-signing-key") {
		t.Fatal("secret was rendered on the page")
	}
}
