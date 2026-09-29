// MCP form command quoting, environment parsing, and credential retention semantics.
// Wire-format command tokenization and sentinel deletion operate inside unexported form
// submission models before reaching any daemon RPC, unreachable by daemon E2E.
package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func typeText(m CapabilityPageModel, text string) CapabilityPageModel {
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyExtended, Text: text})
	return m
}

func key(m CapabilityPageModel, k rune) CapabilityPageModel {
	m, _ = m.Update(tea.KeyPressMsg{Code: k})
	return m
}

func mcpPage(t *testing.T) CapabilityPageModel {
	m := NewCapabilityPageModel(nil, "s", "/workspace", "mcp")
	m.Home = t.TempDir()
	m.SetSize(100, 30)
	m.Loading = false
	m.ExtensionEnabled = true
	return m
}

func TestAddingAnHTTPServerAsksForAuthBeforeSaving(t *testing.T) {
	m := mcpPage(t)
	m = typeText(m, "n")
	if m.Form == nil || m.Form.current() != fieldURL {
		t.Fatal("n should open the add form on the URL")
	}
	m = typeText(m, "http://100.64.0.19:8787/mcp")
	if got := m.Form.Inputs[fieldName].Value(); got != "mcp-100-64-0-19" {
		t.Fatalf("name should follow the URL, got %q", got)
	}
	m = key(m, tea.KeyEnter) // name
	m = key(m, tea.KeyEnter) // bearer token
	if m.Form.current() != fieldToken || m.Saving {
		t.Fatalf("enter should walk to the bearer token without saving, at %q", m.Form.current())
	}
	m = typeText(m, "sensitive-token")
	if strings.Contains(ansi.Strip(m.View()), "sensitive-token") || !strings.Contains(ansi.Strip(m.View()), "bearer token") {
		t.Fatalf("the token field must be labelled and masked:\n%s", ansi.Strip(m.View()))
	}
	sub, err := m.Form.submission(nil)
	if err != nil {
		t.Fatal(err)
	}
	if sub.Name != "mcp-100-64-0-19" || sub.Server.Type != "http" || sub.Server.URL != "http://100.64.0.19:8787/mcp" || sub.Secrets["bearerToken"] != "sensitive-token" {
		t.Fatalf("unexpected submission %+v", sub)
	}
}

func TestStdioServerParsesItsCommandAndSuggestsAName(t *testing.T) {
	m := mcpPage(t)
	m = typeText(m, "n")
	m = key(m, tea.KeyUp)
	m = key(m, tea.KeyRight)
	if m.Form.Transport != "stdio" {
		t.Fatal("← → should switch the transport")
	}
	m = key(m, tea.KeyDown)
	m = typeText(m, `npx -y @modelcontextprotocol/server-filesystem "/tmp/my dir"`)
	m = key(m, tea.KeyDown)
	m = key(m, tea.KeyDown)
	m = typeText(m, "TOKEN=abc DEBUG=1")
	sub, err := m.Form.submission(nil)
	if err != nil {
		t.Fatal(err)
	}
	if sub.Name != "filesystem" || sub.Server.Command != "npx" || strings.Join(sub.Server.Args, "|") != "-y|@modelcontextprotocol/server-filesystem|/tmp/my dir" {
		t.Fatalf("unexpected stdio submission %+v", sub)
	}
	env, _ := sub.Secrets["env"].(map[string]any)
	if token, kept := sub.Secrets["bearerToken"]; env["TOKEN"] != "abc" || env["DEBUG"] != "1" || !kept || token != nil {
		t.Fatalf("env should be stored privately, got %+v", sub.Secrets)
	}
	if strings.Contains(ansi.Strip(m.View()), "abc") {
		t.Fatal("env values must be masked")
	}
}

func TestEditingKeepsOrRemovesStoredSecrets(t *testing.T) {
	stored := daemon.MCPSecretNames{BearerToken: true, Headers: []string{"X-Key"}}
	enabled := false
	f := newMCPForm("docs", config.MCPServer{Type: "http", URL: "https://docs.example/mcp", Enabled: &enabled}, stored)
	sub, err := f.submission([]capabilityItem{{ID: "docs"}})
	_, token := sub.Secrets["bearerToken"]
	_, headers := sub.Secrets["headers"]
	if err != nil || token || headers || sub.Server.Enabled == nil {
		t.Fatalf("a blank edit must keep stored secrets and other fields: %+v %v", sub, err)
	}
	if !strings.Contains(ansi.Strip(strings.Join(f.view(100), "\n")), "stored · blank keeps it") {
		t.Fatal("edit form should say a token is stored")
	}
	f.Inputs[fieldToken].SetValue("-")
	f.Inputs[fieldHeader].SetValue("X-Key")
	f.Inputs[fieldValue].SetValue("-")
	sub, _ = f.submission(nil)
	removed, _ := sub.Secrets["headers"].(map[string]any)
	header, named := removed["X-Key"]
	if token, ok := sub.Secrets["bearerToken"]; !ok || token != nil || !named || header != nil {
		t.Fatalf("- should remove stored secrets: %+v", sub.Secrets)
	}
}
