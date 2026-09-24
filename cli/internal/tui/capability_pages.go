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

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

// CapabilityPageModel owns a dedicated session page for one source of agent
// context. MCP servers are added and edited through one form (mcp_form.go).
type CapabilityPageModel struct {
	Conn                                                        *daemon.Connection
	SessionID, Workspace, Kind, Home                            string
	Items                                                       []capabilityItem
	Prefs                                                       config.CapabilityPrefs
	Cursor, Width, Height, Generation                           int
	Global, Loading, Saving, ExtensionEnabled, ConfirmExtension bool
	ConfirmDelete                                               bool
	Form                                                        *mcpForm
	Error, Notice                                               string
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
	// Pages open on the global defaults; s scopes changes to this session.
	return CapabilityPageModel{Conn: conn, SessionID: sessionID, Workspace: workspace, Kind: kind, Home: config.HomeDir(), Loading: true, Global: true}
}
func (m *CapabilityPageModel) SetSize(w, h int) {
	m.Width = w
	m.Height = h
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

var mcpHeaderName = regexp.MustCompile(`^[!#$%&'*+.^_` + "`" + `|~0-9A-Za-z-]+$`)
var mcpEnvName = regexp.MustCompile(`^[A-Za-z_][A-Za-z_0-9]*$`)

// saveMCPCmd writes a server and its credentials together and reloads the
// session once. If the reload fails (the server cannot connect), both files
// are restored, so a half-configured server is never left behind.
func (m CapabilityPageModel) saveMCPCmd(sub mcpSubmission, gen int) tea.Cmd {
	return func() tea.Msg {
		return capabilitySavedMsg{Gen: gen, Err: m.replaceMCP(sub.Name, &sub.Server, sub.Secrets)}
	}
}

func (m CapabilityPageModel) deleteMCPCmd(name string, gen int) tea.Cmd {
	return func() tea.Msg {
		return capabilitySavedMsg{Gen: gen, Err: m.replaceMCP(name, nil, config.MCPServerSecrets{})}
	}
}

func (m CapabilityPageModel) replaceMCP(name string, server *config.MCPServer, secrets config.MCPServerSecrets) error {
	if err := m.checkIdle(); err != nil {
		return err
	}
	servers, err := config.ReadMCPServers(m.Home)
	if err != nil {
		return err
	}
	credentials, err := config.ReadMCPCredentials(m.Home)
	if err != nil {
		return err
	}
	var previous *config.MCPServer
	if prior, ok := servers[name]; ok {
		previous = &prior
	}
	priorSecrets := credentials.Servers[name]
	restore := func() {
		_ = config.PutMCPServer(m.Home, name, previous)
		_ = config.SetMCPServerSecrets(m.Home, name, priorSecrets)
	}
	if err = config.SetMCPServerSecrets(m.Home, name, secrets); err != nil {
		return err
	}
	if err = config.PutMCPServer(m.Home, name, server); err != nil {
		restore()
		return err
	}
	if err = m.reload(); err != nil {
		restore()
		return err
	}
	return nil
}

var mcpName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`)

// openForm starts adding a server, or editing the selected one with its
// stored credentials summarized (never shown).
func (m *CapabilityPageModel) openForm(edit bool) {
	m.Error, m.Notice = "", ""
	if !edit {
		m.Form = newMCPForm("", config.MCPServer{Type: "http"}, config.MCPServerSecrets{})
		return
	}
	item := m.Items[m.Cursor]
	credentials, err := config.ReadMCPCredentials(m.Home)
	if err != nil {
		m.Error = err.Error()
		return
	}
	m.Form = newMCPForm(item.ID, item.Server, credentials.Servers[item.ID])
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
		m.Form = nil
		m.ConfirmDelete = false
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
		if m.Form != nil {
			if msg.Type == tea.KeyEsc {
				m.Form = nil
				m.Error = ""
				return m, nil
			}
			submit, cmd := m.Form.update(msg)
			if !submit {
				return m, cmd
			}
			sub, err := m.Form.submission(m.Items)
			if err != nil {
				m.Error = err.Error()
				return m, nil
			}
			m.Error = ""
			m.Saving = true
			m.Generation++
			return m, m.saveMCPCmd(sub, m.Generation)
		}
		if m.ConfirmDelete {
			m.ConfirmDelete = false
			if msg.Type == tea.KeyEnter && len(m.Items) > 0 {
				m.Saving = true
				m.Generation++
				return m, m.deleteMCPCmd(m.Items[m.Cursor].ID, m.Generation)
			}
			return m, nil
		}
		if msg.Type == tea.KeyEsc || msg.Type == tea.KeyCtrlC {
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
					m.openForm(false)
				}
			case "d":
				if m.Kind == "mcp" && len(m.Items) > 0 {
					m.ConfirmDelete = true
				}
			case "e":
				// Re-enables a server switched off in extensions.json.
				if m.Kind == "mcp" && len(m.Items) > 0 && m.Items[m.Cursor].Server.Enabled != nil && !*m.Items[m.Cursor].Server.Enabled {
					item := m.Items[m.Cursor]
					server := item.Server
					server.Enabled = nil
					credentials, err := config.ReadMCPCredentials(m.Home)
					if err != nil {
						m.Error = err.Error()
						return m, nil
					}
					m.Saving = true
					m.Generation++
					return m, m.saveMCPCmd(mcpSubmission{Name: item.ID, Server: server, Secrets: credentials.Servers[item.ID]}, m.Generation)
				}
			}
		case tea.KeyEnter:
			if m.Kind == "mcp" && len(m.Items) > 0 {
				m.openForm(true)
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
	rows := []string{titleRule(width, brand("albedo")+" "+DefaultStyles.Muted.Render("/"+m.Kind), DefaultStyles.Faint.Render(scope)), ""}
	if m.Error != "" {
		rows = append(rows, DefaultStyles.Error.Render(ansi.Truncate(m.Error, width, "…")))
	}
	if m.Notice != "" {
		rows = append(rows, DefaultStyles.Faint.Render(m.Notice))
	}
	if m.Loading {
		rows = append(rows, DefaultStyles.Faint.Render("loading "+heading+"…"))
		return strings.Join(rows, "\n")
	}
	if !m.ExtensionEnabled {
		rows = append(rows, DefaultStyles.Warning.Render("extension off")+DefaultStyles.Decor.Render(" · ")+keyHints(hint{"E", "enable (restarts Python worker)"}))
	}
	if len(m.Items) == 0 {
		rows = append(rows, DefaultStyles.Faint.Render("no "+strings.ToLower(heading)+" found"))
	}
	listRows := max(1, m.Height-12)
	start := max(0, m.Cursor-listRows+1)
	for i := start; i < min(len(m.Items), start+listRows); i++ {
		item := m.Items[i]
		label := DefaultStyles.Success.Render("on ")
		if !m.selectedEnabled(item) || m.Kind == "mcp" && item.Server.Enabled != nil && !*item.Server.Enabled {
			label = DefaultStyles.Faint.Render("off")
		}
		mark := "  "
		if i == m.Cursor {
			mark = selectBar() + " "
		}
		detail := ""
		if m.Kind == "mcp" {
			detail = DefaultStyles.Faint.Render(" · " + item.Detail)
		}
		row := ansi.Truncate(mark+label+"  "+item.Title+detail, width, "…")
		if i == m.Cursor {
			row = selectedLine(row, width)
		}
		rows = append(rows, row)
	}
	if m.Form != nil {
		rows = append(rows, "")
		rows = append(rows, m.Form.view(width)...)
		if m.Saving {
			rows = append(rows, "connecting and reloading…")
		}
	} else if m.ConfirmExtension {
		rows = append(rows, "", DefaultStyles.Warning.Render("enable extension and reload workers?")+" "+keyHints(hint{"enter", "confirm"}, hint{"esc", "cancel"}))
	} else if m.ConfirmDelete && len(m.Items) > 0 {
		rows = append(rows, "", DefaultStyles.Warning.Render("delete MCP server "+m.Items[m.Cursor].ID+" and its stored credentials?")+" "+keyHints(hint{"enter", "confirm"}, hint{"any other key", "cancels"}))
	} else if m.Saving {
		rows = append(rows, "saving and reloading…")
	} else {
		if len(m.Items) > 0 {
			selected := m.Items[m.Cursor]
			detail := selected.Detail
			if m.Kind == "mcp" {
				auth := "no credentials"
				if selected.HasSecret {
					auth = "credentials stored privately"
				}
				detail += " · " + auth
				if selected.Server.Enabled != nil && !*selected.Server.Enabled {
					detail += " · disabled in extensions.json · e enable"
				}
			}
			rows = append(rows, "", DefaultStyles.Faint.Render(ansi.Truncate(detail, width, "…")))
		}
		rows = append(rows, "", keyHints(hint{"↑↓", "select"}, hint{"space", "toggle"}, hint{"s", "session"}, hint{"g", "global"}, hint{"r", "refresh"}, hint{"esc", "back"}))
		if m.Kind == "mcp" {
			rows = append(rows, keyHints(hint{"n", "add server"}, hint{"enter", "edit"}, hint{"d", "delete"}))
		}
	}
	if m.Height > 0 && len(rows) > m.Height {
		rows = append(rows[:max(1, m.Height-1)], rows[len(rows)-1])
	}
	return strings.Join(rows, "\n")
}
