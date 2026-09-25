package tui

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func typeText(m CapabilityPageModel, text string) CapabilityPageModel {
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(text)})
	return m
}

func key(m CapabilityPageModel, k tea.KeyType) CapabilityPageModel {
	m, _ = m.Update(tea.KeyMsg{Type: k})
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
	if sub.Name != "mcp-100-64-0-19" || sub.Server.Type != "http" || sub.Server.URL != "http://100.64.0.19:8787/mcp" || sub.Secrets.BearerToken != "sensitive-token" {
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
	if sub.Secrets.Env["TOKEN"] != "abc" || sub.Secrets.Env["DEBUG"] != "1" || sub.Secrets.BearerToken != "" {
		t.Fatalf("env should be stored privately, got %+v", sub.Secrets)
	}
	if strings.Contains(ansi.Strip(m.View()), "abc") {
		t.Fatal("env values must be masked")
	}
}

func TestEditingKeepsOrRemovesStoredSecrets(t *testing.T) {
	stored := config.MCPServerSecrets{BearerToken: "old", Headers: map[string]string{"X-Key": "k"}}
	enabled := false
	f := newMCPForm("docs", config.MCPServer{Type: "http", URL: "https://docs.example/mcp", Enabled: &enabled}, stored)
	sub, err := f.submission([]capabilityItem{{ID: "docs"}})
	if err != nil || sub.Secrets.BearerToken != "old" || sub.Secrets.Headers["X-Key"] != "k" || sub.Server.Enabled == nil {
		t.Fatalf("a blank edit must keep stored secrets and other fields: %+v %v", sub, err)
	}
	if !strings.Contains(strings.Join(f.view(100), "\n"), "stored · blank keeps it") {
		t.Fatal("edit form should say a token is stored")
	}
	f.Inputs[fieldToken].SetValue("-")
	f.Inputs[fieldHeader].SetValue("X-Key")
	f.Inputs[fieldValue].SetValue("-")
	sub, _ = f.submission(nil)
	if sub.Secrets.BearerToken != "" || len(sub.Secrets.Headers) != 0 {
		t.Fatalf("- should remove stored secrets: %+v", sub.Secrets)
	}
}

func TestFailedConnectionRestoresConfigAndKeepsTheForm(t *testing.T) {
	daemonStub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/status") {
			_ = json.NewEncoder(w).Encode(map[string]any{"running": false, "idle": true})
			return
		}
		http.Error(w, `{"error":"mcp server unreachable"}`, http.StatusConflict)
	}))
	defer daemonStub.Close()
	address, _ := url.Parse(daemonStub.URL)
	port, _ := strconv.Atoi(address.Port())

	m := mcpPage(t)
	m.Conn = daemon.NewConnection(daemon.ConnectionSnapshot{Port: port, Token: "t", Version: 2}, "")
	m = typeText(m, "n")
	m = typeText(m, "https://mcp.linear.app/mcp")
	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyCtrlS})
	if !m.Saving || cmd == nil {
		t.Fatal("ctrl+s should save")
	}
	m, _ = m.Update(cmd())
	if m.Form == nil || m.Error == "" || m.Form.Inputs[fieldURL].Value() != "https://mcp.linear.app/mcp" {
		t.Fatalf("a failed save must keep the form and show why, error=%q", m.Error)
	}
	servers, _ := config.ReadMCPServers(m.Home)
	if len(servers) != 0 {
		t.Fatalf("failed server must be rolled back, got %+v", servers)
	}
	if _, err := os.Stat(filepath.Join(m.Home, "mcp-credentials.json")); err == nil {
		if creds, _ := config.ReadMCPCredentials(m.Home); len(creds.Servers) != 0 {
			t.Fatalf("failed credentials must be rolled back, got %+v", creds)
		}
	}
	if got := m.Form.Inputs[fieldName].Value(); got != "linear" {
		t.Fatalf("name should drop the mcp. prefix, got %q", got)
	}
}
