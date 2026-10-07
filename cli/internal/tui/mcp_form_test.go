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

func typeMCP(m CapabilityPageModel, text string) CapabilityPageModel {
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyExtended, Text: text})
	return m
}

func key(m CapabilityPageModel, k rune) CapabilityPageModel {
	m, _ = m.Update(tea.KeyPressMsg{Code: k})
	return m
}

func ctrl(m CapabilityPageModel, k rune) CapabilityPageModel {
	m, _ = m.Update(tea.KeyPressMsg{Code: k, Mod: tea.ModCtrl})
	return m
}

func mcpPage(t *testing.T) CapabilityPageModel {
	t.Helper()
	m := NewCapabilityPageModel(nil, "s", "mcp")
	m.SetSize(100, 30)
	m.Loading = false
	m.ExtensionEnabled = true
	return m
}

func TestAddingAnHTTPServerAsksForAuthBeforeSaving(t *testing.T) {
	m := mcpPage(t)
	m = ctrl(m, 'o')
	if m.Form == nil || m.Form.current() != fieldURL {
		t.Fatal("ctrl+o should open the add form on the URL")
	}
	m = typeMCP(m, "http://100.64.0.19:8787/mcp")
	if got := m.Form.Inputs[fieldName].Value(); got != "mcp-100-64-0-19" {
		t.Fatalf("name should follow the URL, got %q", got)
	}
	m = key(m, tea.KeyEnter) // name
	m = key(m, tea.KeyEnter) // bearer token
	if m.Form.current() != fieldToken || m.Saving {
		t.Fatalf("enter should walk to the bearer token without saving, at %q", m.Form.current())
	}
	m = typeMCP(m, "sensitive-token")
	if strings.Contains(ansi.Strip(m.View()), "sensitive-token") || !strings.Contains(ansi.Strip(m.View()), "bearer token") {
		t.Fatalf("the token field must be labelled and masked:\n%s", ansi.Strip(m.View()))
	}
	sub, err := m.Form.submission(nil)
	if err != nil {
		t.Fatal(err)
	}
	if sub.Name != "mcp-100-64-0-19" || sub.Server.Type != "http" || sub.Server.URL != "http://100.64.0.19:8787/mcp" || (sub.Secrets.BearerToken == nil || *sub.Secrets.BearerToken != "sensitive-token") {
		t.Fatalf("unexpected submission %+v", sub)
	}
}

func TestStdioServerParsesItsCommandAndSuggestsAName(t *testing.T) {
	m := mcpPage(t)
	m = ctrl(m, 'o')
	m = key(m, tea.KeyUp)
	m = key(m, tea.KeyRight)
	if m.Form.Transport != "stdio" {
		t.Fatal("← → should switch the transport")
	}
	m = key(m, tea.KeyDown)
	m = typeMCP(m, `npx -y @modelcontextprotocol/server-filesystem "/tmp/my dir"`)
	m = key(m, tea.KeyDown)
	m = key(m, tea.KeyDown)
	m = typeMCP(m, "TOKEN=abc DEBUG=1")
	sub, err := m.Form.submission(nil)
	if err != nil {
		t.Fatal(err)
	}
	if sub.Name != "filesystem" || sub.Server.Command != "npx" || strings.Join(sub.Server.Args, "|") != "-y|@modelcontextprotocol/server-filesystem|/tmp/my dir" {
		t.Fatalf("unexpected stdio submission %+v", sub)
	}
	env := sub.Secrets.Env
	if env["TOKEN"] == nil || *env["TOKEN"] != "abc" || env["DEBUG"] == nil || *env["DEBUG"] != "1" || !sub.Secrets.RemoveBearerToken {
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
	if err != nil || sub.Secrets.BearerToken != nil || sub.Secrets.RemoveBearerToken || sub.Secrets.Headers != nil || sub.Secrets.ClearHeaders || sub.Server.Enabled == nil {
		t.Fatalf("a blank edit must keep stored secrets and other fields: %+v %v", sub, err)
	}

	f.Inputs[fieldToken].SetValue("-")
	f.Inputs[fieldHeader].SetValue("X-Key")
	f.Inputs[fieldValue].SetValue("-")
	sub, _ = f.submission(nil)
	removed := sub.Secrets.Headers
	header, named := removed["X-Key"]
	if !sub.Secrets.RemoveBearerToken || !named || header != nil {
		t.Fatalf("- should remove stored secrets: %+v", sub.Secrets)
	}
}
