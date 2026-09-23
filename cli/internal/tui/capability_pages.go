package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

// CapabilityPageModel owns a dedicated session page for one source of agent
// context. The list stays visible while the MCP detail pane edits a server.
type CapabilityPageModel struct {
	Conn                                                                      *daemon.Connection
	SessionID, Workspace, Kind, Home                                          string
	Items                                                                     []capabilityItem
	Prefs                                                                     config.CapabilityPrefs
	Cursor, Width, Height, Generation                                         int
	Global, Detail, Auth, Loading, Saving, ExtensionEnabled, ConfirmExtension bool
	Edit, FieldName                                                           string
	Input                                                                     textinput.Model
	Error, Notice                                                             string
}
type capabilityItem struct {
	ID, Title, Detail string
	Server            config.MCPServer
	HasSecret         bool
	Draft             bool
}
type capabilityLoadedMsg struct {
	Items            []capabilityItem
	Prefs            config.CapabilityPrefs
	ExtensionEnabled bool
	Gen              int
	Err              error
}
type capabilitySavedMsg struct {
	Gen int
	Err error
}
type CapabilityPageDoneMsg struct{}
type CapabilityPageChangedMsg struct{}

type ChatOpenCapabilityPageMsg struct{ Kind string }

func NewCapabilityPageModel(conn *daemon.Connection, sessionID, workspace, kind string) CapabilityPageModel {
	ti := textinput.New()
	ti.Prompt = ""
	ti.CharLimit = 4096
	// Pages open on the global defaults; s scopes changes to this session.
	return CapabilityPageModel{Conn: conn, SessionID: sessionID, Workspace: workspace, Kind: kind, Home: config.HomeDir(), Input: ti, Loading: true, Global: true}
}
func (m *CapabilityPageModel) SetSize(w, h int) {
	m.Width = w
	m.Height = h
	m.Input.Width = max(1, w-12)
}
func (m CapabilityPageModel) Init() tea.Cmd { return m.loadCmd(m.Generation) }
func (m CapabilityPageModel) loadCmd(gen int) tea.Cmd {
	home, workspace, kind := m.Home, m.Workspace, m.Kind
	return func() tea.Msg {
		prefs, err := config.ReadCapabilityPrefs(home)
		if err != nil {
			return capabilityLoadedMsg{Gen: gen, Err: err}
		}
		var items []capabilityItem
		switch kind {
		case "skills":
			items, err = discoverSkills(home, workspace)
		case "instructions":
			items = discoverInstructions(home, workspace)
		case "mcp":
			var servers map[string]config.MCPServer
			servers, err = config.ReadMCPServers(home)
			if err == nil {
				var credentials config.MCPCredentials
				credentials, err = config.ReadMCPCredentials(home)
				if err == nil {
					for name, server := range servers {
						secret := credentials.Servers[name]
						address := server.URL
						if server.Type == "stdio" {
							address = server.Command
						}
						items = append(items, capabilityItem{ID: name, Title: name, Detail: server.Type + " · " + address, Server: server, HasSecret: secret.BearerToken != "" || len(secret.Env) > 0 || len(secret.Headers) > 0})
					}
				}
			}
		default:
			err = errors.New("unknown capability page")
		}
		sort.Slice(items, func(i, j int) bool { return items[i].ID < items[j].ID })
		enabled := true
		if err == nil && m.Conn != nil {
			path := fmt.Sprintf("/sessions/%s/extensions", url.PathEscape(m.SessionID))
			var extensions []ExtensionItem
			extensions, err = daemon.Request[[]ExtensionItem](context.Background(), m.Conn, path, nil)
			if err == nil {
				for _, ext := range extensions {
					if ext.Name == kind {
						enabled = ext.Enabled
						break
					}
				}
			}
		}
		return capabilityLoadedMsg{Items: items, Prefs: prefs, ExtensionEnabled: enabled, Gen: gen, Err: err}
	}
}

// Discovery mirrors the daemon's root ordering. Disabled entries remain listed;
// the daemon's prepared catalog remains authoritative after a reload.
func discoverSkills(home, workspace string) ([]capabilityItem, error) {
	userHome, _ := os.UserHomeDir()
	roots := []string{filepath.Join(workspace, ".albedo", "skills"), filepath.Join(workspace, ".agents", "skills"), filepath.Join(userHome, ".albedo", "skills"), filepath.Join(userHome, ".agents", "skills"), filepath.Join(userHome, ".prime", "agent", "skills")}
	seen := map[string]bool{}
	var items []capabilityItem
	for _, root := range roots {
		dirs, err := os.ReadDir(root)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return nil, err
		}
		for _, dir := range dirs {
			name := dir.Name()
			if seen[name] || !dir.IsDir() {
				continue
			}
			path := filepath.Join(root, name, "SKILL.md")
			info, err := os.Stat(path)
			if err != nil || !info.Mode().IsRegular() {
				continue
			}
			seen[name] = true
			items = append(items, capabilityItem{ID: name, Title: name, Detail: path})
		}
	}
	return items, nil
}
func discoverInstructions(home, workspace string) []capabilityItem {
	var items []capabilityItem
	rootNames := []string{"AGENTS.md", "CLAUDE.md"}
	entries, _ := os.ReadDir(workspace)
	for _, e := range entries {
		for _, wanted := range rootNames {
			if strings.EqualFold(e.Name(), wanted) && e.Type().IsRegular() {
				items = append(items, capabilityItem{ID: "project:" + e.Name(), Title: e.Name(), Detail: filepath.Join(workspace, e.Name())})
			}
		}
	}
	userHome, _ := os.UserHomeDir()
	for _, group := range []struct{ scope, base string }{{"project", workspace}, {"global", userHome}} {
		for _, folder := range []string{".agents", ".albedo"} {
			path := filepath.Join(group.base, folder)
			entries, _ := os.ReadDir(path)
			for _, e := range entries {
				if !e.Type().IsRegular() || !strings.EqualFold(filepath.Ext(e.Name()), ".md") {
					continue
				}
				display := filepath.Join(folder, e.Name())
				if group.scope == "global" {
					display = filepath.Join("~", folder, e.Name())
				}
				items = append(items, capabilityItem{ID: group.scope + ":" + display, Title: display, Detail: filepath.Join(path, e.Name())})
			}
		}
	}
	return items
}

func (m CapabilityPageModel) reload() error {
	if m.Conn == nil {
		return errors.New("daemon connection unavailable")
	}
	path := fmt.Sprintf("/sessions/%s/commands", url.PathEscape(m.SessionID))
	_, err := daemon.Request[map[string]any](context.Background(), m.Conn, path, map[string]any{"name": "/reload", "args": map[string]string{"target": "session"}})
	return err
}
func (m CapabilityPageModel) checkIdle() error {
	if m.Conn == nil {
		return errors.New("daemon connection unavailable")
	}
	path := fmt.Sprintf("/sessions/%s/status", url.PathEscape(m.SessionID))
	status, err := daemon.Request[daemon.AgentStatus](context.Background(), m.Conn, path, nil)
	if err != nil {
		return err
	}
	if status.Running && !status.Idle {
		return errors.New("session must be idle to change capabilities")
	}
	return nil
}
func (m CapabilityPageModel) enableExtensionCmd(gen int) tea.Cmd {
	return func() tea.Msg {
		if err := m.checkIdle(); err != nil {
			return capabilitySavedMsg{Gen: gen, Err: err}
		}
		path := fmt.Sprintf("/sessions/%s/extensions", url.PathEscape(m.SessionID))
		_, err := daemon.Request[[]ExtensionItem](context.Background(), m.Conn, path, map[string]any{"name": m.Kind, "enabled": true})
		return capabilitySavedMsg{Gen: gen, Err: err}
	}
}

func (m CapabilityPageModel) toggleCmd(item capabilityItem, gen int) tea.Cmd {
	return func() tea.Msg {
		if err := m.checkIdle(); err != nil {
			return capabilitySavedMsg{Gen: gen, Err: err}
		}
		before, err := config.ReadCapabilityPrefs(m.Home)
		if err != nil {
			return capabilitySavedMsg{Gen: gen, Err: err}
		}
		var old bool
		var had bool
		next := !before.Enabled(m.SessionID, m.Kind, item.ID)
		if m.Global {
			old, had = before.Global[m.Kind][item.ID]
			if had {
				next = !old
			} else {
				next = false
			}
		} else {
			old, had = before.Sessions[m.SessionID][m.Kind][item.ID]
		}
		if err = config.SetCapability(m.Home, m.SessionID, m.Kind, item.ID, m.Global, next); err != nil {
			return capabilitySavedMsg{Gen: gen, Err: err}
		}
		if err = m.reload(); err != nil {
			if had {
				_ = config.SetCapability(m.Home, m.SessionID, m.Kind, item.ID, m.Global, old)
			} else {
				_ = config.ClearCapability(m.Home, m.SessionID, m.Kind, item.ID, m.Global)
			}
		}
		return capabilitySavedMsg{Gen: gen, Err: err}
	}
}
func (m CapabilityPageModel) secretCmd(item capabilityItem, value string, gen int) tea.Cmd {
	return func() tea.Msg {
		if err := m.checkIdle(); err != nil {
			return capabilitySavedMsg{Gen: gen, Err: err}
		}
		old, err := config.ReadMCPCredentials(m.Home)
		if err != nil {
			return capabilitySavedMsg{Gen: gen, Err: err}
		}
		secret := old.Servers[item.ID]
		before := secret
		secret.BearerToken = value
		if err = config.SetMCPServerSecrets(m.Home, item.ID, secret); err != nil {
			return capabilitySavedMsg{Gen: gen, Err: err}
		}
		if err = m.reload(); err != nil {
			_ = config.SetMCPServerSecrets(m.Home, item.ID, before)
		}
		return capabilitySavedMsg{Gen: gen, Err: err}
	}
}
func (m CapabilityPageModel) secretFieldCmd(item capabilityItem, field, key, value string, gen int) tea.Cmd {
	return func() tea.Msg {
		if err := m.checkIdle(); err != nil {
			return capabilitySavedMsg{Gen: gen, Err: err}
		}
		old, err := config.ReadMCPCredentials(m.Home)
		if err != nil {
			return capabilitySavedMsg{Gen: gen, Err: err}
		}
		before := old.Servers[item.ID]
		secret := before
		if field == "headers" {
			next := make(map[string]string, len(before.Headers)+1)
			for k, v := range before.Headers {
				next[k] = v
			}
			next[key] = value
			secret.Headers = next
		} else {
			next := make(map[string]string, len(before.Env)+1)
			for k, v := range before.Env {
				next[k] = v
			}
			next[key] = value
			secret.Env = next
		}
		if err = config.SetMCPServerSecrets(m.Home, item.ID, secret); err != nil {
			return capabilitySavedMsg{Gen: gen, Err: err}
		}
		err = m.reload()
		if err != nil {
			_ = config.SetMCPServerSecrets(m.Home, item.ID, before)
		}
		return capabilitySavedMsg{Gen: gen, Err: err}
	}
}

var mcpHeaderName = regexp.MustCompile(`^[!#$%&'*+.^_` + "`" + `|~0-9A-Za-z-]+$`)
var mcpEnvName = regexp.MustCompile(`^[A-Za-z_][A-Za-z_0-9]*$`)

func (m CapabilityPageModel) serverCmd(item capabilityItem, server *config.MCPServer, gen int) tea.Cmd {
	return func() tea.Msg {
		if err := m.checkIdle(); err != nil {
			return capabilitySavedMsg{Gen: gen, Err: err}
		}
		var previous *config.MCPServer
		if !item.Draft && item.Server.Type != "" {
			prior := item.Server
			previous = &prior
		}
		if err := config.PutMCPServer(m.Home, item.ID, server); err != nil {
			return capabilitySavedMsg{Gen: gen, Err: err}
		}
		err := m.reload()
		if err != nil {
			_ = config.PutMCPServer(m.Home, item.ID, previous)
		}
		return capabilitySavedMsg{Gen: gen, Err: err}
	}
}

var mcpName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`)

func (m *CapabilityPageModel) startEdit(kind string, initial string) {
	m.Edit = kind
	m.Input.Reset()
	m.Input.EchoMode = textinput.EchoNormal
	if kind == "secret" || kind == "header-value" || kind == "env-value" {
		m.Input.EchoMode = textinput.EchoPassword
	} else {
		m.Input.SetValue(initial)
	}
	m.Input.Focus()
	m.Error = ""
}
func (m CapabilityPageModel) Update(msg tea.Msg) (CapabilityPageModel, tea.Cmd) {
	switch msg := msg.(type) {
	case capabilityLoadedMsg:
		if msg.Gen != m.Generation {
			return m, nil
		}
		m.Loading = false
		if msg.Err != nil {
			m.Error = msg.Err.Error()
			return m, nil
		}
		selected := ""
		if m.Cursor < len(m.Items) {
			selected = m.Items[m.Cursor].ID
		}
		m.Items = msg.Items
		m.Prefs = msg.Prefs
		m.ExtensionEnabled = msg.ExtensionEnabled
		m.Error = ""
		for i, item := range m.Items {
			if item.ID == selected {
				m.Cursor = i
				break
			}
		}
		if m.Cursor >= len(m.Items) {
			m.Cursor = max(0, len(m.Items)-1)
		}
		return m, nil
	case capabilitySavedMsg:
		if msg.Gen != m.Generation {
			return m, nil
		}
		m.Saving = false
		if msg.Err != nil {
			m.Error = msg.Err.Error()
			return m, nil
		}
		m.Edit = ""
		m.Notice = "saved · session reloaded"
		m.Loading = true
		return m, tea.Batch(m.loadCmd(m.Generation), func() tea.Msg { return CapabilityPageChangedMsg{} })
	case tea.KeyMsg:
		if m.Saving {
			return m, nil
		}
		if m.ConfirmExtension {
			if msg.Type == tea.KeyEsc {
				m.ConfirmExtension = false
				return m, nil
			}
			if msg.Type == tea.KeyEnter {
				m.ConfirmExtension = false
				m.Saving = true
				m.Generation++
				return m, m.enableExtensionCmd(m.Generation)
			}
			return m, nil
		}
		if m.Edit != "" {
			if msg.Type == tea.KeyEsc {
				m.Edit = ""
				m.Input.Blur()
				return m, nil
			}
			if msg.Type == tea.KeyEnter {
				value := strings.TrimSpace(m.Input.Value())
				mode := m.Edit
				m.Edit = ""
				m.Input.Blur()
				if len(m.Items) == 0 && mode != "new-name" {
					return m, nil
				}
				var item capabilityItem
				if len(m.Items) > 0 {
					item = m.Items[m.Cursor]
				}
				switch mode {
				case "header-name", "env-name":
					valid := mcpHeaderName.MatchString(value)
					if mode == "env-name" {
						valid = mcpEnvName.MatchString(value)
					}
					if !valid {
						m.Error = "invalid header or environment name"
						return m, nil
					}
					m.FieldName = value
					if mode == "header-name" {
						m.startEdit("header-value", "")
					} else {
						m.startEdit("env-value", "")
					}
					return m, nil
				case "header-value", "env-value":
					if value == "" {
						m.Error = "secret cannot be empty"
						return m, nil
					}
					field := "headers"
					if mode == "env-value" {
						field = "env"
					}
					m.Saving = true
					m.Generation++
					return m, m.secretFieldCmd(item, field, m.FieldName, value, m.Generation)
				case "secret":
					m.Saving = true
					m.Generation++
					return m, m.secretCmd(item, value, m.Generation)
				case "url":
					if value == "" {
						m.Error = "endpoint cannot be empty"
						return m, nil
					}
					server := item.Server
					server.URL = value
					m.Saving = true
					m.Generation++
					return m, m.serverCmd(item, &server, m.Generation)
				case "new-name":
					if !mcpName.MatchString(value) {
						m.Error = "use 1–64 letters, digits, _ or -"
						return m, nil
					}
					for _, existing := range m.Items {
						if existing.ID == value {
							m.Error = "server already exists"
							return m, nil
						}
					}
					m.Items = append(m.Items, capabilityItem{ID: value, Title: value, Draft: true, Server: config.MCPServer{Type: "http"}})
					m.Cursor = len(m.Items) - 1
					m.startEdit("new-url", "")
					return m, nil
				case "new-url":
					if value == "" {
						m.Error = "endpoint cannot be empty"
						return m, nil
					}
					server := config.MCPServer{Type: "http", URL: value}
					m.Saving = true
					m.Generation++
					return m, m.serverCmd(item, &server, m.Generation)
				}
				return m, nil
			}
			var cmd tea.Cmd
			m.Input, cmd = m.Input.Update(msg)
			return m, cmd
		}
		if msg.Type == tea.KeyEsc || msg.Type == tea.KeyCtrlC {
			if m.Auth {
				m.Auth = false
				return m, nil
			}
			if m.Detail {
				m.Detail = false
				return m, nil
			}
			return m, func() tea.Msg { return CapabilityPageDoneMsg{} }
		}
		if m.Loading {
			return m, nil
		}
		switch msg.Type {
		case tea.KeyUp:
			if m.Cursor > 0 {
				m.Cursor--
			}
		case tea.KeyDown:
			if m.Cursor < len(m.Items)-1 {
				m.Cursor++
			}
		case tea.KeyRunes:
			switch msg.String() {
			case "r":
				m.Loading = true
				m.Generation++
				return m, m.loadCmd(m.Generation)
			case "g":
				m.Global = true
			case "s":
				m.Global = false
			case "E":
				if !m.ExtensionEnabled {
					m.ConfirmExtension = true
				}
			case "n":
				if m.Kind == "mcp" {
					m.startEdit("new-name", "")
				}
			case "e":
				if m.Detail && m.Kind == "mcp" && len(m.Items) > 0 {
					item := m.Items[m.Cursor]
					server := item.Server
					next := server.Enabled != nil && !*server.Enabled
					server.Enabled = &next
					m.Saving = true
					m.Generation++
					return m, m.serverCmd(item, &server, m.Generation)
				}
			case "a":
				if m.Detail && m.Kind == "mcp" && len(m.Items) > 0 {
					m.Auth = true
				}
			case "b":
				if m.Auth && len(m.Items) > 0 {
					m.startEdit("secret", "")
				}
			case "h":
				if m.Auth && len(m.Items) > 0 {
					m.startEdit("header-name", "")
				}
			case "v":
				if m.Auth && len(m.Items) > 0 {
					m.startEdit("env-name", "")
				}
			case "u":
				if m.Detail && m.Kind == "mcp" && len(m.Items) > 0 && m.Items[m.Cursor].Server.Type == "http" {
					m.startEdit("url", m.Items[m.Cursor].Server.URL)
				}
			case "x":
				if m.Auth && len(m.Items) > 0 {
					m.Saving = true
					m.Generation++
					return m, m.secretCmd(m.Items[m.Cursor], "", m.Generation)
				}
			}
		case tea.KeyEnter:
			if m.Kind == "mcp" && len(m.Items) > 0 {
				m.Detail = true
			}
		case tea.KeySpace:
			if len(m.Items) > 0 {
				m.Saving = true
				m.Generation++
				return m, m.toggleCmd(m.Items[m.Cursor], m.Generation)
			}
		}
	}
	return m, nil
}
func (m CapabilityPageModel) selectedEnabled(item capabilityItem) bool {
	if m.Global {
		if value, ok := m.Prefs.Global[m.Kind][item.ID]; ok {
			return value
		}
		return true
	}
	return m.Prefs.Enabled(m.SessionID, m.Kind, item.ID)
}

func (m CapabilityPageModel) View() string {
	width := max(1, m.Width)
	heading := map[string]string{"skills": "Skills", "instructions": "Instruction files", "mcp": "MCP servers"}[m.Kind]
	scope := "this session"
	if m.Global {
		scope = "global default"
	}
	rows := []string{"albedo /" + m.Kind + " · " + scope, ""}
	if m.Error != "" {
		rows = append(rows, DefaultStyles.Error.Render(ansi.Truncate(m.Error, width, "…")))
	}
	if m.Notice != "" {
		rows = append(rows, DefaultStyles.Faint.Render(m.Notice))
	}
	if m.Loading {
		rows = append(rows, "loading "+heading+"…")
		return strings.Join(rows, "\n")
	}
	if !m.ExtensionEnabled {
		rows = append(rows, "extension off · E enable (restarts Python worker)")
	}
	if len(m.Items) == 0 {
		rows = append(rows, "no "+strings.ToLower(heading)+" found")
	}
	listRows := max(1, m.Height-12)
	start := max(0, m.Cursor-listRows+1)
	for i := start; i < min(len(m.Items), start+listRows); i++ {
		item := m.Items[i]
		label := "on "
		if !m.selectedEnabled(item) || m.Kind == "mcp" && item.Server.Enabled != nil && !*item.Server.Enabled {
			label = "off"
		}
		mark := "  "
		if i == m.Cursor {
			mark = "› "
		}
		detail := ""
		if m.Kind == "mcp" {
			detail = " · " + item.Detail
		}
		rows = append(rows, ansi.Truncate(mark+label+"  "+item.Title+detail, width, "…"))
	}
	if len(m.Items) > 0 {
		selected := m.Items[m.Cursor]
		rows = append(rows, "", ansi.Truncate(selected.Detail, width, "…"))
		if m.Kind == "mcp" && m.Detail {
			status := "not set"
			if selected.HasSecret {
				status = "stored privately"
			}
			rows = append(rows, "transport: "+selected.Server.Type, "auth: "+status)
			if m.Auth {
				rows = append(rows, "authentication · b bearer · h HTTP header · v stdio env · x remove bearer · esc back")
			} else {
				rows = append(rows, "a authentication · e enable/disable server · u edit URL · esc back")
			}
		}
	}
	if m.ConfirmExtension {
		rows = append(rows, "", "enable extension and reload workers? enter confirm · esc cancel")
	} else if m.Edit != "" {
		label := map[string]string{"secret": "Bearer token (masked)", "url": "MCP URL", "new-name": "Server name", "new-url": "MCP URL", "header-name": "HTTP header name", "header-value": "Header value (masked)", "env-name": "Environment name", "env-value": "Environment value (masked)"}[m.Edit]
		rows = append(rows, "", label+": "+m.Input.View(), "enter save · esc cancel")
	} else if m.Saving {
		rows = append(rows, "saving and reloading…")
	} else {
		rows = append(rows, "", "↑↓ select · space toggle · s session · g global · r refresh · esc back")
		if m.Kind == "mcp" {
			rows = append(rows, "enter details · n add HTTP server")
		}
	}
	if m.Height > 0 && len(rows) > m.Height {
		rows = append(rows[:max(1, m.Height-1)], rows[len(rows)-1])
	}
	return strings.Join(rows, "\n")
}
