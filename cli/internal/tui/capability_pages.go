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
	"slices"
	"strings"
	"sync/atomic"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// CapabilityPageModel owns a dedicated session page for one source of agent
// context. MCP servers are added and edited through one form (mcp_form.go).
type CapabilityPageModel struct {
	Conn                                       *daemon.Connection
	SessionID, Workspace, Kind, Home           string
	Items                                      []capabilityItem
	Prefs                                      config.CapabilityPrefs
	Global, ExtensionEnabled, ConfirmExtension bool
	ConfirmDelete                              bool
	Form                                       *mcpForm
	page
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

// Commands outlive closed pages; globally unique generations reject their replies.
var capabilityGen atomic.Int64

func nextCapabilityGen() int { return int(capabilityGen.Add(1)) }

func NewCapabilityPageModel(conn *daemon.Connection, sessionID, workspace, kind string) CapabilityPageModel {
	// Pages open on the global defaults; s scopes changes to this session.
	return CapabilityPageModel{Conn: conn, SessionID: sessionID, Workspace: workspace, Kind: kind, Home: config.HomeDir(), Global: true, page: page{Loading: true, Generation: nextCapabilityGen()}}
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
			items, err = mcpItems(home)
		default:
			err = errors.New("unknown capability page")
		}
		slices.SortFunc(items, func(a, b capabilityItem) int { return strings.Compare(a.ID, b.ID) })
		enabled := true
		if err == nil && m.Conn != nil {
			path := fmt.Sprintf("/sessions/%s/extensions", url.PathEscape(m.SessionID))
			var extensions []ExtensionItem
			extensions, err = daemon.Request[[]ExtensionItem](context.Background(), m.Conn, path, nil)
			if i := slices.IndexFunc(extensions, func(ext ExtensionItem) bool { return ext.Name == kind }); err == nil && i >= 0 {
				enabled = extensions[i].Enabled
			}
		}
		return capabilityLoadedMsg{Items: items, Prefs: prefs, ExtensionEnabled: enabled, Gen: gen, Err: err}
	}
}

// mcpItems lists the configured servers with whether credentials are stored
// for them (never their contents).
func mcpItems(home string) ([]capabilityItem, error) {
	servers, err := config.ReadMCPServers(home)
	if err != nil {
		return nil, err
	}
	credentials, err := config.ReadMCPCredentials(home)
	if err != nil {
		return nil, err
	}
	items := make([]capabilityItem, 0, len(servers))
	for name, server := range servers {
		secret := credentials.Servers[name]
		address := pick(server.Type == "stdio", server.Command, server.URL)
		items = append(items, capabilityItem{
			ID: name, Title: name, Detail: server.Type + " · " + address, Server: server,
			HasSecret: secret.BearerToken != "" || len(secret.Env) > 0 || len(secret.Headers) > 0,
		})
	}
	return items, nil
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
	entries, _ := os.ReadDir(workspace)
	for _, e := range entries {
		if e.Type().IsRegular() && (strings.EqualFold(e.Name(), "AGENTS.md") || strings.EqualFold(e.Name(), "CLAUDE.md")) {
			items = append(items, capabilityItem{ID: "project:" + e.Name(), Title: e.Name(), Detail: filepath.Join(workspace, e.Name())})
		}
	}
	userHome, _ := os.UserHomeDir()
	for _, group := range []struct{ scope, base string }{{"project", workspace}, {"global", userHome}} {
		for _, folder := range []string{".agents", ".albedo"} {
			path := filepath.Join(group.base, folder)
			subEntries, _ := os.ReadDir(path)
			for _, e := range subEntries {
				if !e.Type().IsRegular() || !strings.EqualFold(filepath.Ext(e.Name()), ".md") {
					continue
				}
				display := pick(group.scope == "global", filepath.Join("~", folder, e.Name()), filepath.Join(folder, e.Name()))
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
		var old, had bool
		next := false
		if m.Global {
			old, had = before.Global[m.Kind][item.ID]
			// The first global toggle writes an explicit off; after that the
			// stored value flips. A session override must not leak into it.
			if had {
				next = !old
			}
		} else {
			old, had = before.Sessions[m.SessionID][m.Kind][item.ID]
			next = !before.Enabled(m.SessionID, m.Kind, item.ID)
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
	if err = config.PutMCPServer(m.Home, name, server); err == nil {
		err = m.reload()
	}
	if err != nil {
		restore()
	}
	return err
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

func (m CapabilityPageModel) save(cmd func(int) tea.Cmd) (CapabilityPageModel, tea.Cmd) {
	m.Saving = true
	m.Generation = nextCapabilityGen()
	return m, cmd(m.Generation)
}

func (m CapabilityPageModel) Update(msg tea.Msg) (CapabilityPageModel, tea.Cmd) {
	switch msg := msg.(type) {
	case capabilityLoadedMsg:
		if !m.settle(msg.Gen, msg.Err, &m.Loading) {
			return m, nil
		}
		m.Cursor = reselect(m.Cursor, m.Items, msg.Items, func(item capabilityItem) string { return item.ID })
		m.Items, m.Prefs, m.ExtensionEnabled, m.Error = msg.Items, msg.Prefs, msg.ExtensionEnabled, ""
		return m, nil
	case capabilitySavedMsg:
		if !m.settle(msg.Gen, msg.Err, &m.Saving) {
			return m, nil
		}
		m.Form = nil
		m.ConfirmDelete = false
		m.Notice = "saved · session reloaded"
		m.Loading, m.Generation = true, nextCapabilityGen()
		return m, tea.Batch(m.loadCmd(m.Generation), func() tea.Msg { return CapabilityPageChangedMsg{} })
	case tea.PasteMsg:
		if m.Form == nil || m.Saving {
			return m, nil
		}
		_, cmd := m.Form.update(msg)
		return m, cmd
	case tea.KeyPressMsg:
		if m.Saving {
			return m, nil
		}
		if m.ConfirmExtension {
			switch msg.String() {
			case "esc":
				m.ConfirmExtension = false
			case "enter":
				m.ConfirmExtension = false
				return m.save(m.enableExtensionCmd)
			}
			return m, nil
		}
		if m.Form != nil {
			if msg.String() == "esc" {
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
			return m.save(func(gen int) tea.Cmd { return m.saveMCPCmd(sub, gen) })
		}
		if m.ConfirmDelete {
			m.ConfirmDelete = false
			if msg.String() == "enter" && len(m.Items) > 0 {
				return m.save(func(gen int) tea.Cmd { return m.deleteMCPCmd(m.Items[m.Cursor].ID, gen) })
			}
			return m, nil
		}
		if msg.String() == "esc" || msg.String() == "ctrl+c" {
			return m, func() tea.Msg { return CapabilityPageDoneMsg{} }
		}
		if m.Loading {
			return m, nil
		}
		if m.step(msg.String(), len(m.Items)) {
			return m, nil
		}
		mcp := m.Kind == "mcp"
		hasItems := len(m.Items) > 0
		switch msg.String() {
		case "r":
			m.Loading = true
			m.Generation = nextCapabilityGen()
			return m, m.loadCmd(m.Generation)
		case "g", "s":
			m.Global = msg.String() == "g"
		case "E":
			if !m.ExtensionEnabled {
				m.ConfirmExtension = true
			}
		case "n":
			if mcp {
				m.openForm(false)
			}
		case "d":
			if mcp && hasItems {
				m.ConfirmDelete = true
			}
		case "e":
			// Re-enables a server switched off in extensions.json.
			if mcp && hasItems {
				if item := m.Items[m.Cursor]; item.Server.Enabled != nil && !*item.Server.Enabled {
					server := item.Server
					server.Enabled = nil
					credentials, err := config.ReadMCPCredentials(m.Home)
					if err != nil {
						m.Error = err.Error()
						return m, nil
					}
					return m.save(func(gen int) tea.Cmd {
						return m.saveMCPCmd(mcpSubmission{Name: item.ID, Server: server, Secrets: credentials.Servers[item.ID]}, gen)
					})
				}
			}
		case "enter":
			if mcp && hasItems {
				m.openForm(true)
			}
		case "space":
			if hasItems {
				return m.save(func(gen int) tea.Cmd { return m.toggleCmd(m.Items[m.Cursor], gen) })
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
	mcp := m.Kind == "mcp"
	heading := map[string]string{"skills": "Skills", "instructions": "Instruction files", "mcp": "MCP servers"}[m.Kind]
	scope := pick(m.Global, "global default", "this session")
	rows := m.header("/"+m.Kind, scope)
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
	list := make([]string, len(m.Items))
	for i, item := range m.Items {
		label := DefaultStyles.Success.Render("on ")
		if !m.selectedEnabled(item) || (mcp && item.Server.Enabled != nil && !*item.Server.Enabled) {
			label = DefaultStyles.Faint.Render("off")
		}
		detail := pick(mcp, DefaultStyles.Faint.Render(" · "+item.Detail), "")
		list[i] = listRow(i == m.Cursor, label+"  "+item.Title+detail, width)
	}
	rows = append(rows, scrolled(list, m.Cursor, max(1, m.Height-12))...)
	switch {
	case m.Form != nil:
		rows = append(rows, "")
		rows = append(rows, m.Form.view(width)...)
		if m.Saving {
			rows = append(rows, "connecting and reloading…")
		}
	case m.ConfirmExtension:
		rows = append(rows, "", DefaultStyles.Warning.Render("enable extension and reload workers?")+" "+keyHints(hint{"enter", "confirm"}, hint{"esc", "cancel"}))
	case m.ConfirmDelete && len(m.Items) > 0:
		rows = append(rows, "", DefaultStyles.Warning.Render("delete MCP server "+m.Items[m.Cursor].ID+" and its stored credentials?")+" "+keyHints(hint{"enter", "confirm"}, hint{"any other key", "cancels"}))
	case m.Saving:
		rows = append(rows, "saving and reloading…")
	default:
		if len(m.Items) > 0 {
			selected := m.Items[m.Cursor]
			detail := selected.Detail
			if mcp {
				auth := pick(selected.HasSecret, "credentials stored privately", "no credentials")
				detail += " · " + auth
				if selected.Server.Enabled != nil && !*selected.Server.Enabled {
					detail += " · disabled in extensions.json · e enable"
				}
			}
			rows = append(rows, "", DefaultStyles.Faint.Render(ansi.Truncate(detail, width, "…")))
		}
		rows = append(rows, "", keyHints(hint{"↑↓", "select"}, hint{"space", "toggle"}, hint{"s", "session"}, hint{"g", "global"}, hint{"r", "refresh"}, hint{"esc", "back"}))
		if mcp {
			rows = append(rows, keyHints(hint{"n", "add server"}, hint{"enter", "edit"}, hint{"d", "delete"}))
		}
	}
	return m.fit(rows)
}
