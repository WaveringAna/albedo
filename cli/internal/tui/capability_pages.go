package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strings"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// CapabilityPageModel owns a dedicated session page for one source of agent
// context. MCP servers are added and edited through one form (mcp_form.go).
type CapabilityPageModel struct {
	Prefs                            config.CapabilityPrefs
	Conn                             *daemon.Connection
	Form                             *mcpForm
	SessionID, Kind                  string
	Items                            []capabilityItem
	Revision                         string
	SessionETag, GlobalETag, MCPETag string
	Diagnostics                      []string
	page
	Global, ExtensionEnabled, ConfirmExtension bool
	ConfirmDelete                              bool
}
type capabilityItem struct {
	ID, Title, Detail string
	Candidate         daemon.CatalogCandidate
	Secrets           daemon.MCPSecretNames
	Server            config.MCPServer
}
type capabilityLoadedMsg struct {
	SessionETag, GlobalETag, MCPETag string
	Prefs                            config.CapabilityPrefs
	Revision                         string
	Diagnostics                      []string
	Err                              error
	Items                            []capabilityItem
	Gen                              int
	ExtensionEnabled                 bool
}
type capabilitySavedMsg struct {
	Err     error
	Warning string
	Gen     int
}
type CapabilityPageDoneMsg struct{}
type CapabilityPageChangedMsg struct{}

type ChatOpenCapabilityPageMsg struct{ Kind string }

func NewCapabilityPageModel(conn *daemon.Connection, sessionID, kind string) CapabilityPageModel {
	// Pages open on the global defaults; s scopes changes to this session.
	return CapabilityPageModel{Conn: conn, SessionID: sessionID, Kind: kind, Global: true, page: page{Loading: true, Generation: nextPageGeneration()}}
}
func (m CapabilityPageModel) Init() tea.Cmd { return m.loadCmd(m.Generation) }
func (m CapabilityPageModel) loadCmd(gen int) tea.Cmd {
	kind := m.Kind
	return func() tea.Msg {
		catalog, err := daemon.GetCapabilityCatalog(context.Background(), m.Conn, m.SessionID)
		if err != nil {
			return capabilityLoadedMsg{Gen: gen, Err: err}
		}
		settings, err := daemon.GetSettings(context.Background(), m.Conn)
		if err != nil {
			return capabilityLoadedMsg{Gen: gen, Err: err}
		}
		configuration, err := daemon.GetSessionConfiguration(context.Background(), m.Conn, m.SessionID)
		if err != nil {
			return capabilityLoadedMsg{Gen: gen, Err: err}
		}
		items := []capabilityItem{}
		switch kind {
		case "mcp":
			items = mcpItems(settings)
			for i := range items {
				for _, candidate := range catalog.Candidates {
					if candidate.Kind == "mcp" && candidate.PreferenceKey != nil && *candidate.PreferenceKey == "mcp:"+items[i].ID {
						items[i].Candidate = candidate
					}
				}
			}
		case "skills", "instructions":
			for _, candidate := range catalog.Candidates {
				if candidate.Kind == kind {
					items = append(items, capabilityItem{ID: candidate.ID, Title: candidate.Title, Detail: candidate.Source, Candidate: candidate})
				}
			}
		default:
			return capabilityLoadedMsg{Gen: gen, Err: errors.New("unknown capability page")}
		}
		slices.SortFunc(items, func(a, b capabilityItem) int { return strings.Compare(a.ID, b.ID) })
		enabled := catalog.Extensions[kind]
		return capabilityLoadedMsg{Items: items, Revision: catalog.Revision, Diagnostics: catalog.Diagnostics, Prefs: settings.Capabilities, ExtensionEnabled: enabled, SessionETag: configuration.ETag, GlobalETag: settings.ETags["capabilities"], MCPETag: settings.ETags["mcp"], Gen: gen}

	}
}

// mcpItems lists the configured servers with the names of the secrets the
// daemon holds for them (never their contents).
func mcpItems(settings daemon.Settings) []capabilityItem {
	items := make([]capabilityItem, 0, len(settings.MCP))
	for name, server := range settings.MCP {
		address := server.URL
		if server.Type == "stdio" {
			address = server.Command
		}
		items = append(items, capabilityItem{ID: name, Title: name, Detail: server.Type + " · " + address, Server: server, Secrets: settings.Credentials.MCP[name]})
	}
	return items
}

func (m CapabilityPageModel) enableExtensionCmd(gen int) tea.Cmd {
	return func() tea.Msg {
		_, err := daemon.SelectExtension(context.Background(), m.Conn, m.SessionID, daemon.ExtensionSelectionRequest{Name: m.Kind, Scope: "session", ETag: m.SessionETag, Enabled: new(true)})
		if err != nil {
			return capabilitySavedMsg{Gen: gen, Err: err}
		}
		reloaded, reloadErr := daemon.ReloadSession(context.Background(), m.Conn, m.SessionID, daemon.ReloadRequest{Target: "session"})
		warning := reloaded.Message()
		switch {
		case reloadErr != nil:
			warning = "Extension enabled; reload failed: " + reloadErr.Error()
			if _, uncertain := errors.AsType[*daemon.UncertainOutcomeError](reloadErr); uncertain {
				warning = "Extension enabled; reload not confirmed: " + reloadErr.Error()
			}
		case reloaded.Session == nil:
			warning = "Extension enabled; reload returned no session outcome."
		case reloaded.Session.State != "applied":
			warning = "Extension enabled; session reload " + reloaded.Session.State + ". " + reloaded.Message()
		}
		return capabilitySavedMsg{Gen: gen, Warning: warning}
	}
}

func (m CapabilityPageModel) toggleCmd(item capabilityItem, gen int) tea.Cmd {
	next := !m.selectedEnabled(item)
	return m.choiceCmd(item, &next, gen)
}

func (m CapabilityPageModel) choiceCmd(item capabilityItem, enabled *bool, gen int) tea.Cmd {
	scope := "session"
	if m.Global {
		scope = "global"
	}
	etag := m.SessionETag
	if scope == "global" {
		etag = m.GlobalETag
	}
	return func() tea.Msg {
		var result daemon.ReloadResult
		var err error
		if m.Kind == "mcp" {
			result, err = daemon.SetCapability(context.Background(), m.Conn, m.SessionID, daemon.CapabilitySelectionRequest{Kind: m.Kind, Name: capabilityChoiceID(item, scope), Revision: m.Revision, ETag: etag, Scope: scope, Enabled: enabled})
		} else {
			result, err = daemon.SetCatalogCapability(context.Background(), m.Conn, m.SessionID, daemon.CatalogCapabilityRequest{Revision: m.Revision, ID: item.ID, Kind: m.Kind, ETag: etag, Scope: scope, Enabled: enabled})
		}
		return capabilitySavedMsg{Gen: gen, Err: err, Warning: strings.TrimSpace(result.Message + " " + result.Warning)}
	}
}

var mcpHeaderName = regexp.MustCompile(`^[!#$%&'*+.^_` + "`" + `|~0-9A-Za-z-]+$`)
var mcpEnvName = regexp.MustCompile(`^[A-Za-z_][A-Za-z_0-9]*$`)

// saveMCPCmd saves the definition and secrets together under the observed group validator.
func (m CapabilityPageModel) saveMCPCmd(sub mcpSubmission, gen int) tea.Cmd {
	return func() tea.Msg {
		result, err := daemon.SaveMCP(context.Background(), m.Conn, m.SessionID, daemon.MCPUpdateRequest{Name: sub.Name, ETag: m.MCPETag, StoredSecrets: m.storedSecrets(sub.Name), Server: &sub.Server, Secrets: sub.Secrets})
		return capabilitySavedMsg{Gen: gen, Err: err, Warning: strings.TrimSpace(result.Message + " " + result.Warning)}
	}
}

func (m CapabilityPageModel) deleteMCPCmd(name string, gen int) tea.Cmd {
	return func() tea.Msg {
		result, err := daemon.SaveMCP(context.Background(), m.Conn, m.SessionID, daemon.MCPUpdateRequest{Name: name, ETag: m.MCPETag, Server: nil, Secrets: daemon.MCPSecretsPatch{}})
		return capabilitySavedMsg{Gen: gen, Err: err, Warning: strings.TrimSpace(result.Message + " " + result.Warning)}
	}
}

var mcpName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`)

// openForm starts adding a server, or editing the selected one with its
// stored credentials summarized (never shown).
func (m *CapabilityPageModel) openForm(edit bool) {
	m.Error, m.Notice = "", ""
	if !edit {
		m.Form = newMCPForm("", config.MCPServer{Type: "http"}, daemon.MCPSecretNames{})
		return
	}
	item := m.Items[m.Cursor]
	m.Form = newMCPForm(item.ID, item.Server, item.Secrets)
}

func (m CapabilityPageModel) save(cmd func(int) tea.Cmd) (CapabilityPageModel, tea.Cmd) {
	m.Saving = true
	m.Generation = nextPageGeneration()
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
		m.Revision, m.Diagnostics = msg.Revision, msg.Diagnostics
		m.SessionETag, m.GlobalETag, m.MCPETag = msg.SessionETag, msg.GlobalETag, msg.MCPETag
		return m, nil
	case capabilitySavedMsg:
		if msg.Gen == m.Generation {
			if apiErr, ok := errors.AsType[*daemon.APIError](msg.Err); ok && apiErr.Code == "catalog_changed" {
				m.Saving, m.Loading, m.Error = false, true, ""
				m.Notice = "The list changed. Review it before trying again."
				m.Generation = nextPageGeneration()
				return m, m.loadCmd(m.Generation)
			}
		}
		if !m.settle(msg.Gen, msg.Err, &m.Saving) {
			return m, nil
		}
		m.Form = nil
		m.ConfirmDelete = false
		m.Notice = "Saved. Reload the session to apply the selection."
		if msg.Warning != "" {
			m.Notice = msg.Warning
		}
		m.Loading, m.Generation = true, nextPageGeneration()
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
			m.Generation = nextPageGeneration()
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
					enabled := true
					server.Enabled = &enabled
					return m.save(func(gen int) tea.Cmd {
						return m.saveMCPCmd(mcpSubmission{Name: item.ID, Server: server, Secrets: daemon.MCPSecretsPatch{}}, gen)
					})
				}
			}
		case "enter":
			if mcp && hasItems {
				m.openForm(true)
			}
		case "space":
			if hasItems && m.canToggle(m.Items[m.Cursor]) {
				return m.save(func(gen int) tea.Cmd { return m.toggleCmd(m.Items[m.Cursor], gen) })
			}
		case "x":
			if !mcp && hasItems && m.canClear(m.Items[m.Cursor]) {
				return m.save(func(gen int) tea.Cmd { return m.choiceCmd(m.Items[m.Cursor], nil, gen) })
			}
		}
	}
	return m, nil
}
func (m CapabilityPageModel) canToggle(item capabilityItem) bool {
	if m.Kind == "mcp" {
		return true
	}
	candidate := item.Candidate
	return candidate.PreferenceKey != nil && candidate.ShadowedBy == nil && (candidate.Valid || m.selectedEnabled(item))
}

func (m CapabilityPageModel) canClear(item capabilityItem) bool {
	candidate := item.Candidate
	if candidate.PreferenceKey == nil || candidate.ShadowedBy != nil {
		return false
	}
	if m.Global {
		return candidate.GlobalPreference != nil
	}
	return candidate.SessionOverride != nil
}

func (m CapabilityPageModel) selectedEnabled(item capabilityItem) bool {
	if item.Candidate.ID != "" || m.Kind != "mcp" {
		if m.Global {
			return item.Candidate.GlobalPreference == nil || *item.Candidate.GlobalPreference
		}
		return item.Candidate.EffectiveEnabled
	}
	if m.Global {
		if enabled, ok := m.Prefs.Global["mcp"][item.ID]; ok {
			return enabled
		}
	}
	return item.Server.Enabled == nil || *item.Server.Enabled
}

func enabledLabel(enabled bool) string {
	if enabled {
		return "on"
	}
	return "off"
}

func (m CapabilityPageModel) View() string {
	width := max(1, m.Width)
	mcp := m.Kind == "mcp"
	heading := map[string]string{"skills": "Skills", "instructions": "Instruction files", "mcp": "MCP servers"}[m.Kind]
	scope := "this session"
	if m.Global {
		scope = "global default"
	}
	rows := m.header("/"+m.Kind, scope)
	if m.Loading {
		rows = append(rows, DefaultStyles.Faint.Render("loading "+heading+"…"))
		return strings.Join(rows, "\n")
	}
	if m.ConfirmExtension || (m.ConfirmDelete && len(m.Items) > 0) {
		question := "Enable the extension selection? Reload this session to apply it."
		if m.ConfirmDelete {
			question = "Its stored credentials will also be removed. Delete MCP server " + m.Items[m.Cursor].ID + "?"
		}
		rows = append(rows, "")
		for line := range strings.SplitSeq(ansi.Wrap(question, width, " "), "\n") {
			rows = append(rows, DefaultStyles.Warning.Render(line))
		}
		cancel := hint{"esc", "cancel"}
		if m.ConfirmDelete {
			cancel = hint{"any other key", "cancels"}
		}
		rows = append(rows, keyHints(hint{"enter", "confirm"}, cancel))
		return m.fit(rows)
	}
	if !m.ExtensionEnabled {
		rows = append(rows, DefaultStyles.Warning.Render("Extension is off")+DefaultStyles.Decor.Render(" · ")+keyHints(hint{"E", "enable (reloads this session)"}))
	}
	if len(m.Diagnostics) > 0 {
		diagnostic := m.Diagnostics[0]
		if len(m.Diagnostics) > 1 {
			diagnostic = fmt.Sprintf("%d discovery diagnostics: %s", len(m.Diagnostics), diagnostic)
		}
		rows = append(rows, DefaultStyles.Warning.Render(ansi.Truncate(diagnostic, width, "…")))
	}
	if len(m.Items) == 0 {
		rows = append(rows, DefaultStyles.Faint.Render("No "+strings.ToLower(heading)+" found."))
	}
	list := make([]string, len(m.Items))
	for i, item := range m.Items {
		label := DefaultStyles.Success.Render("on ")
		if !m.selectedEnabled(item) || (mcp && item.Server.Enabled != nil && !*item.Server.Enabled) {
			label = DefaultStyles.Faint.Render("off")
		}
		if !mcp {
			switch {
			case !item.Candidate.Valid:
				label = DefaultStyles.Warning.Render("invalid")
			case item.Candidate.ShadowedBy != nil:
				label = DefaultStyles.Faint.Render("shadowed")
			}
		}
		detail := ""
		if mcp {
			detail = DefaultStyles.Faint.Render(" · " + item.Detail)
		}
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
	case m.Saving:
		rows = append(rows, "saving and reloading…")
	default:
		if len(m.Items) > 0 {
			selected := m.Items[m.Cursor]
			detail := selected.Detail
			if mcp {
				auth := "no credentials"
				if selected.Secrets.Any() {
					auth = "credentials stored privately"
				}
				detail += " · " + auth
				if selected.Server.Enabled != nil && !*selected.Server.Enabled {
					detail += " · disabled in extensions.json · press e to enable"
				}
			}
			rows = append(rows, "", DefaultStyles.Faint.Render(ansi.Truncate(detail, width, "…")))
			if !mcp {
				candidate := selected.Candidate
				if candidate.Diagnostic != nil {
					rows = append(rows, DefaultStyles.Warning.Render(ansi.Truncate(*candidate.Diagnostic, width, "…")))
				}
				global, session := "default", "inherit"
				if candidate.GlobalPreference != nil {
					global = enabledLabel(*candidate.GlobalPreference)
				}
				if candidate.SessionOverride != nil {
					session = enabledLabel(*candidate.SessionOverride)
				}
				state := fmt.Sprintf("global: %s · session: %s · enabled: %s · eligible on reload: %s", global, session, enabledLabel(candidate.EffectiveEnabled), enabledLabel(candidate.Eligible))
				rows = append(rows, DefaultStyles.Faint.Render(ansi.Truncate(state, width, "…")))
			}
		}
		hints := []hint{{"↑↓", "select"}}
		if len(m.Items) > 0 && m.canToggle(m.Items[m.Cursor]) {
			hints = append(hints, hint{"space", "toggle"})
		}
		if !mcp && len(m.Items) > 0 && m.canClear(m.Items[m.Cursor]) {
			hints = append(hints, hint{"x", "inherit"})
		}
		hints = append(hints, hint{"s", "session"}, hint{"g", "global"}, hint{"r", "refresh"}, hint{"esc", "back"})
		rows = append(rows, "", keyHints(hints...))
		if mcp {
			rows = append(rows, keyHints(hint{"n", "add server"}, hint{"enter", "edit"}, hint{"d", "delete"}))
		}
	}
	return m.fit(rows)
}

func capabilityChoiceID(item capabilityItem, scope string) string {
	if scope == "global" {
		return item.Candidate.ID
	}
	return item.ID
}
func (m CapabilityPageModel) storedSecrets(name string) daemon.MCPSecretNames {
	for _, item := range m.Items {
		if item.ID == name {
			return item.Secrets
		}
	}
	return daemon.MCPSecretNames{}
}
