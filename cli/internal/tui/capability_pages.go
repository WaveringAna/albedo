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

// CapabilityPageModel lists one kind of agent context: skills, instruction
// files, or MCP servers. Enter changes the global default and shift+enter
// changes this session only. MCP servers are added and edited through one
// form (mcp_form.go) that opens over the list.
type CapabilityPageModel struct {
	Prefs                            config.CapabilityPrefs
	Conn                             *daemon.Connection
	Form                             *mcpForm
	SessionID, Kind                  string
	Items                            []capabilityItem
	Revision                         string
	SessionETag, GlobalETag, MCPETag string
	Diagnostics                      []string
	ExtensionEnabled                 bool
	pageStatus
	listView
	confirm
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

// The confirmations that are not a scope change; the scopes are the other
// confirm.what values.
const (
	actionEnableExtension = "extension"
	actionDeleteServer    = "delete"
)

// capabilityNouns names what each page lists, singular; counted pluralizes it.
var capabilityNouns = map[string]string{"skills": "skill", "instructions": "instruction file", "mcp": "MCP server"}

var mcpHeaderName = regexp.MustCompile(`^[!#$%&'*+.^_` + "`" + `|~0-9A-Za-z-]+$`)
var mcpEnvName = regexp.MustCompile(`^[A-Za-z_][A-Za-z_0-9]*$`)
var mcpName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`)

func NewCapabilityPageModel(conn *daemon.Connection, sessionID, kind string) CapabilityPageModel {
	noun := capabilityNouns[kind]
	return CapabilityPageModel{
		Conn: conn, SessionID: sessionID, Kind: kind,
		pageStatus: newPageStatus(true),
		listView:   newListView("Search " + noun + "s"),
	}
}

func (m *CapabilityPageModel) SetSize(width, height int) {
	m.pageStatus.SetSize(width, height)
	m.listView.setSize(width, height)
}

// Confirming reports a question waiting for enter or esc.
func (m CapabilityPageModel) Confirming() bool { return m.confirm.asking() }

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
		_, err := daemon.SelectExtension(context.Background(), m.Conn, m.SessionID, daemon.ExtensionSelectionRequest{Name: m.Kind, Scope: scopeSession, ETag: m.SessionETag, Enabled: new(true)})
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

// choiceCmd sends one selection in a scope: enabled sets it, nil drops this
// session's own choice.
func (m CapabilityPageModel) choiceCmd(item capabilityItem, scope string, enabled *bool, gen int) tea.Cmd {
	etag := m.SessionETag
	if scope == scopeGlobal {
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

// openForm starts adding a server, or editing the highlighted one with its
// stored credentials summarized (never shown).
func (m *CapabilityPageModel) openForm(edit bool) {
	m.Error, m.Notice = "", ""
	if !edit {
		m.Form = newMCPForm("", config.MCPServer{Type: "http"}, daemon.MCPSecretNames{})
		return
	}
	item, ok := m.current()
	if !ok {
		return
	}
	m.Form = newMCPForm(item.ID, item.Server, item.Secrets)
}

// save starts the request cmd builds under a fresh generation, so its reply
// is the only one that settles the save.
func (m CapabilityPageModel) save(cmd func(int) tea.Cmd) (CapabilityPageModel, tea.Cmd) {
	m.Saving, m.Error = true, ""
	m.Generation = nextPageGeneration()
	return m, cmd(m.Generation)
}

func (m CapabilityPageModel) Update(msg tea.Msg) (CapabilityPageModel, tea.Cmd) {
	switch msg := msg.(type) {
	case capabilityLoadedMsg:
		if !m.settle(msg.Gen, msg.Err, &m.Loading) {
			return m, nil
		}
		m.Error = ""
		m.Items, m.Prefs, m.ExtensionEnabled = msg.Items, msg.Prefs, msg.ExtensionEnabled
		m.Revision, m.Diagnostics = msg.Revision, msg.Diagnostics
		m.SessionETag, m.GlobalETag, m.MCPETag = msg.SessionETag, msg.GlobalETag, msg.MCPETag
		m.refreshRows()
		return m, nil

	case capabilitySavedMsg:
		if msg.Gen == m.Generation {
			if apiErr, ok := errors.AsType[*daemon.APIError](msg.Err); ok && apiErr.Code == "catalog_changed" {
				m.Saving, m.Loading, m.Error = false, true, ""
				m.confirm.dismiss()
				m.Notice = "The list changed. Review it before trying again."
				m.Generation = nextPageGeneration()
				return m, m.loadCmd(m.Generation)
			}
		}
		if !m.settle(msg.Gen, msg.Err, &m.Saving) {
			m.confirm.failed = msg.Gen == m.Generation
			return m, nil
		}
		m.Form = nil
		m.confirm.dismiss()
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
		switch {
		case m.confirm.asking() && !m.Saving:
			if m.confirm.key(msg) {
				return m.confirmed()
			}
			if !m.confirm.asking() {
				m.Error = ""
			}
			return m, nil
		case m.Form != nil:
			return m.formKey(msg)
		case msg.String() == "esc" || msg.String() == "ctrl+c" || (msg.String() == "ctrl+d" && m.Kind != "mcp"):
			return m, func() tea.Msg { return CapabilityPageDoneMsg{} }
		case m.Loading || m.Saving:
			return m, nil
		}
		return m.listKey(msg)
	}
	cmd := m.listView.update(msg)
	return m, cmd
}

// formKey routes keys to the open form; esc closes it without saving.
func (m CapabilityPageModel) formKey(msg tea.KeyPressMsg) (CapabilityPageModel, tea.Cmd) {
	if m.Saving {
		return m, nil
	}
	if msg.String() == "esc" {
		m.Form, m.Error = nil, ""
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
	return m.save(func(gen int) tea.Cmd { return m.saveMCPCmd(sub, gen) })
}

// listKey acts on the highlighted row, or hands the key to the filter. The
// ctrl+o add key is the only one that differs from the shared list keys.
func (m CapabilityPageModel) listKey(msg tea.KeyPressMsg) (CapabilityPageModel, tea.Cmd) {
	mcp := m.Kind == "mcp"
	item, ok := m.current()
	switch msg.String() {
	case "enter":
		m.askToggle(scopeGlobal)
	case "shift+enter", "alt+enter":
		m.askToggle(scopeSession)
	case "ctrl+x":
		if !mcp && ok && m.canClear(item) {
			m.askToggle(scopeInherit)
		}
	case "ctrl+o":
		if mcp {
			m.openForm(false)
		}
	case "ctrl+e":
		if mcp && ok {
			m.openForm(true)
		}
	case "ctrl+d":
		if mcp && ok {
			m.confirm.ask(actionDeleteServer, item.ID, "delete", fmt.Sprintf("Its stored credentials will also be removed. Delete MCP server %s?", item.Title))
		}
	case "ctrl+g":
		if mcp && ok && serverDisabled(item) {
			return m.enableServer(item)
		}
	case "ctrl+t":
		if !m.ExtensionEnabled {
			m.confirm.ask(actionEnableExtension, m.Kind, "enable", fmt.Sprintf("Enable the %s extension? This reloads this session to apply it.", m.Kind))
		}
	case "ctrl+r":
		m.Loading, m.Error, m.Notice = true, "", ""
		m.Generation = nextPageGeneration()
		return m, m.loadCmd(m.Generation)
	default:
		cmd := m.listView.update(msg)
		return m, cmd
	}
	return m, nil
}

// enableServer turns on a server that extensions.json has switched off.
func (m CapabilityPageModel) enableServer(item capabilityItem) (CapabilityPageModel, tea.Cmd) {
	server := item.Server
	enabled := true
	server.Enabled = &enabled
	return m.save(func(gen int) tea.Cmd {
		return m.saveMCPCmd(mcpSubmission{Name: item.ID, Server: server, Secrets: daemon.MCPSecretsPatch{}}, gen)
	})
}

// askToggle asks before changing a row in one scope, or before dropping
// this session's own choice.
func (m *CapabilityPageModel) askToggle(scope string) {
	item, ok := m.current()
	if !ok || (scope != scopeInherit && !m.canToggle(item, scope)) {
		return
	}
	m.Error = ""
	if scope == scopeInherit {
		m.confirm.ask(scope, item.ID, "follow global", fmt.Sprintf("This session will follow the global default for %s. Remove its own choice?", item.Title))
		return
	}
	verb := "enable"
	if m.enabledIn(item, scope) {
		verb = "disable"
	}
	sentence := strings.ToUpper(verb[:1]) + verb[1:]
	prompt := fmt.Sprintf("Sessions following global defaults will use this change. %s %s globally?", sentence, item.Title)
	if scope == scopeSession {
		prompt = fmt.Sprintf("%s %s for this session only? Reload this session to apply it.", sentence, item.Title)
	}
	m.confirm.ask(scope, item.ID, verb, prompt)
}

// confirmed runs the change the question asked about. The question stays up
// while the change is in flight, so a failure can be retried with enter.
func (m CapabilityPageModel) confirmed() (CapabilityPageModel, tea.Cmd) {
	target, what := m.confirm.target, m.confirm.what
	switch what {
	case actionEnableExtension:
		return m.save(m.enableExtensionCmd)
	case actionDeleteServer:
		return m.save(func(gen int) tea.Cmd { return m.deleteMCPCmd(target, gen) })
	}
	item, ok := m.itemNamed(target)
	if !ok {
		m.confirm.dismiss()
		return m, nil
	}
	if what == scopeInherit {
		return m.save(func(gen int) tea.Cmd { return m.choiceCmd(item, scopeSession, nil, gen) })
	}
	next := !m.enabledIn(item, what)
	return m.save(func(gen int) tea.Cmd { return m.choiceCmd(item, what, &next, gen) })
}

func (m CapabilityPageModel) current() (capabilityItem, bool) {
	row, ok := m.highlighted()
	if !ok {
		return capabilityItem{}, false
	}
	return m.itemNamed(row.key)
}

func (m CapabilityPageModel) itemNamed(id string) (capabilityItem, bool) {
	i := slices.IndexFunc(m.Items, func(item capabilityItem) bool { return item.ID == id })
	if i < 0 {
		return capabilityItem{}, false
	}
	return m.Items[i], true
}

// refreshRows rebuilds the list from the items, keeping the cursor on its row.
func (m *CapabilityPageModel) refreshRows() {
	rows := make([]listEntry, len(m.Items))
	for i, item := range m.Items {
		rows[i] = m.entry(item)
	}
	m.setRows(rows)
}

func (m CapabilityPageModel) canToggle(item capabilityItem, scope string) bool {
	if m.Kind == "mcp" {
		return true
	}
	candidate := item.Candidate
	return candidate.PreferenceKey != nil && candidate.ShadowedBy == nil && (candidate.Valid || m.enabledIn(item, scope))
}

// canClear is whether this session has its own choice to drop.
func (m CapabilityPageModel) canClear(item capabilityItem) bool {
	candidate := item.Candidate
	return candidate.PreferenceKey != nil && candidate.ShadowedBy == nil && candidate.SessionOverride != nil
}

// enabledIn is whether the item is on in one scope: the global default, or
// this session's state.
func (m CapabilityPageModel) enabledIn(item capabilityItem, scope string) bool {
	if item.Candidate.ID != "" || m.Kind != "mcp" {
		if scope == scopeGlobal {
			return item.Candidate.GlobalPreference == nil || *item.Candidate.GlobalPreference
		}
		return item.Candidate.EffectiveEnabled
	}
	if scope == scopeGlobal {
		if enabled, ok := m.Prefs.Global["mcp"][item.ID]; ok {
			return enabled
		}
	}
	return item.Server.Enabled == nil || *item.Server.Enabled
}

// valueOr is the string a nullable field holds, or empty.
func valueOr(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

// serverDisabled is whether extensions.json switches an MCP server off.
func serverDisabled(item capabilityItem) bool {
	return item.Server.Enabled != nil && !*item.Server.Enabled
}

// hasSessionChoice is whether this session differs from the global default
// for the item, which the row shows at its right edge.
func (m CapabilityPageModel) hasSessionChoice(item capabilityItem) bool {
	if m.Kind == "mcp" {
		return m.enabledIn(item, scopeSession) != m.enabledIn(item, scopeGlobal)
	}
	return item.Candidate.SessionOverride != nil
}

// entry is how an item reads in the list: its global state in front, and
// this session's choice at the edge when it differs.
func (m CapabilityPageModel) entry(item capabilityItem) listEntry {
	lead, tag := DefaultStyles.Faint.Render("off"), ""
	if m.enabledIn(item, scopeGlobal) && !serverDisabled(item) {
		lead = DefaultStyles.Success.Render("on")
	}
	entry := listEntry{key: item.ID, lead: lead, name: item.Title, detail: func(width int) []string { return m.details(item, width) }}
	if m.Kind == "mcp" {
		entry.desc = item.Detail
		entry.search = []string{item.Server.URL, item.Server.Command}
	} else {
		candidate := item.Candidate
		entry.desc = valueOr(candidate.Description)
		entry.search = []string{candidate.ID, candidate.Source}
		switch {
		case !candidate.Valid:
			entry.lead = DefaultStyles.Warning.Render("invalid")
		case candidate.ShadowedBy != nil:
			entry.lead = DefaultStyles.Faint.Render("shadowed")
		}
	}
	if m.hasSessionChoice(item) {
		tag = DefaultStyles.Muted.Render("this session: " + onOff(m.enabledIn(item, scopeSession)))
	}
	entry.tag = tag
	return entry
}

// details is the pane: what the item is, where it comes from, and both of
// its states.
func (m CapabilityPageModel) details(item capabilityItem, width int) []string {
	if m.Kind == "mcp" {
		return m.serverDetails(item, width)
	}
	return m.candidateDetails(item, width)
}

func (m CapabilityPageModel) candidateDetails(item capabilityItem, width int) []string {
	c := item.Candidate
	lines := paneTitle(c.Title, valueOr(c.Description), width)
	lines = append(lines, factRows("source", c.Source, width)...)
	if c.ResolvedSource != nil {
		lines = append(lines, factRows("resolved", *c.ResolvedSource, width)...)
	}
	validity, shadow := "valid", "not shadowed"
	if !c.Valid {
		validity = "invalid"
	}
	if c.ShadowedBy != nil {
		shadow = "shadowed by " + *c.ShadowedBy
	}
	lines = append(lines, factRows("validity", validity, width)...)
	lines = append(lines, factRows("shadowing", shadow, width)...)
	global := onOff(m.enabledIn(item, scopeGlobal))
	if c.GlobalPreference == nil {
		global += " (default)"
	}
	session := "follows global"
	if c.SessionOverride != nil {
		session = onOff(*c.SessionOverride) + " (its own choice)"
	}
	lines = append(lines, factRows("global", global, width)...)
	lines = append(lines, factRows("session", session, width)...)
	lines = append(lines, factRows("enabled", onOff(c.EffectiveEnabled)+" · eligible on reload: "+onOff(c.Eligible), width)...)
	if c.Diagnostic != nil {
		lines = append(lines, factRows("problem", *c.Diagnostic, width)...)
	}
	for _, diagnostic := range m.Diagnostics {
		lines = append(lines, factRows("discovery", diagnostic, width)...)
	}
	return append(append(lines, ""), paneNote("Changes apply when the session reloads.", width)...)
}

func (m CapabilityPageModel) serverDetails(item capabilityItem, width int) []string {
	server := item.Server
	lines := paneTitle(item.ID, item.Detail, width)
	lines = append(lines, factRows("transport", server.Type, width)...)
	if server.Type == "stdio" {
		lines = append(lines, factRows("command", joinCommand(server.Command, server.Args), width)...)
		if server.CWD != "" {
			lines = append(lines, factRows("cwd", server.CWD, width)...)
		}
	} else {
		lines = append(lines, factRows("url", server.URL, width)...)
	}
	file := "enabled in extensions.json"
	if serverDisabled(item) {
		file = "disabled in extensions.json"
	}
	lines = append(lines, factRows("config", file, width)...)
	lines = append(lines, factRows("global", onOff(m.enabledIn(item, scopeGlobal)), width)...)
	lines = append(lines, factRows("session", onOff(m.enabledIn(item, scopeSession)), width)...)
	lines = append(lines, factRows("tools", serverTools(server), width)...)
	timeouts := fmt.Sprintf("startup %s · call %s", timeoutLabel(server.StartupTimeoutMs), timeoutLabel(server.CallTimeoutMs))
	lines = append(lines, factRows("timeouts", timeouts, width)...)
	if server.BearerTokenEnvVar != "" {
		lines = append(lines, factRows("token env", server.BearerTokenEnvVar, width)...)
	}
	lines = append(lines, factRows("secrets", storedLabel(item.Secrets), width)...)
	return append(append(lines, ""), paneNote("ctrl+e edits this server. Changes apply when the session reloads.", width)...)
}

// serverTools names which tools the server offers the session.
func serverTools(server config.MCPServer) string {
	if len(server.EnabledTools) > 0 {
		return "only " + strings.Join(server.EnabledTools, ", ")
	}
	if len(server.DisabledTools) > 0 {
		return "all except " + strings.Join(server.DisabledTools, ", ")
	}
	return "all"
}

func timeoutLabel(ms int) string {
	if ms <= 0 {
		return "default"
	}
	return fmt.Sprintf("%dms", ms)
}

// storedLabel names the secrets the daemon holds for a server, never their
// contents.
func storedLabel(names daemon.MCPSecretNames) string {
	if !names.Any() {
		return "none stored"
	}
	var parts []string
	if names.BearerToken {
		parts = append(parts, "bearer token")
	}
	for _, header := range names.Headers {
		parts = append(parts, "header "+header)
	}
	for _, env := range names.Env {
		parts = append(parts, "env "+env)
	}
	return "stored privately · " + strings.Join(parts, ", ")
}

// hints are the keys this page answers now; the ones that do not apply to
// the highlighted row or this extension state are left out.
func (m CapabilityPageModel) hints(item capabilityItem, ok bool) []hint {
	mcp := m.Kind == "mcp"
	hints := []hint{{"↑↓", "move"}}
	if m.extensionOff() {
		hints = append(hints, hint{"ctrl+t", "enable extension"})
	}
	if ok {
		if m.canToggle(item, scopeGlobal) {
			hints = append(hints, hint{"enter", "global"})
		}
		if m.canToggle(item, scopeSession) {
			hints = append(hints, hint{"shift+enter", "this session"})
		}
		if !mcp && m.canClear(item) {
			hints = append(hints, hint{"ctrl+x", "follow global"})
		}
		if mcp {
			hints = append(hints, hint{"ctrl+e", "edit"}, hint{"ctrl+d", "delete"})
		}
		if serverDisabled(item) {
			hints = append(hints, hint{"ctrl+g", "enable server"})
		}
	}
	if mcp {
		hints = append(hints, hint{"ctrl+o", "add server"})
	}
	return append(hints, hint{"ctrl+r", "refresh"}, hint{"esc", "back"})
}

// extensionOff is whether a loaded page found its extension switched off.
func (m CapabilityPageModel) extensionOff() bool {
	return !m.ExtensionEnabled && !m.Loading && m.Error == ""
}

// status is the footer's one line about the page: work in flight, the last
// failure or notice, a reason the list is not live, or the count.
func (m CapabilityPageModel) status() (string, bool) {
	if m.Form != nil && !m.Saving && m.Error == "" {
		return "", false
	}
	switch {
	case m.Saving:
		return DefaultStyles.Busy.Render("saving and reloading…"), true
	case m.Loading:
		return DefaultStyles.Faint.Render("loading…"), false
	case m.Error != "":
		return DefaultStyles.Error.Render(m.Error), true
	case m.Notice != "":
		return DefaultStyles.Warning.Render(m.Notice), true
	case m.extensionOff():
		return DefaultStyles.Warning.Render("extension is off"), true
	case len(m.Diagnostics) > 0:
		return DefaultStyles.Warning.Render(m.diagnosticLine()), true
	}
	return DefaultStyles.Faint.Render(counted(len(m.Items), capabilityNouns[m.Kind])), false
}

func (m CapabilityPageModel) diagnosticLine() string {
	if len(m.Diagnostics) == 1 {
		return m.Diagnostics[0]
	}
	return fmt.Sprintf("%d discovery diagnostics: %s", len(m.Diagnostics), m.Diagnostics[0])
}

func (m CapabilityPageModel) footer(width int) string {
	if m.confirm.asking() && !m.Saving {
		return m.confirm.footer(width, m.Error)
	}
	status, urgent := m.status()
	if m.Form != nil {
		keys := m.Form.footer(width)
		if status == "" {
			return keys
		}
		return " " + ansi.Truncate(status, max(1, width-2), "…") + "\n" + keys
	}
	item, ok := m.current()
	return footerLine(width, m.hints(item, ok), status, urgent)
}

// summary is the highlighted row's source or address, for a width too
// narrow for the detail pane.
func (m CapabilityPageModel) summary() string {
	item, ok := m.current()
	switch {
	case !ok:
		return ""
	case m.Kind == "mcp":
		return item.Detail
	}
	return item.Candidate.Source
}

// formList is the open form in the list's place, clipped to its rows.
func (m CapabilityPageModel) formList(width, height int) []string {
	rows := m.Form.view(width)
	return rows[:min(len(rows), height)]
}

func (m CapabilityPageModel) View() string {
	width := max(1, m.Width)
	lv := m.listView
	noun := capabilityNouns[m.Kind]
	lv.Empty = "No " + noun + "s found."
	switch {
	case m.Loading:
		lv.Empty = "loading " + noun + "s…"
	case m.Error != "" && len(m.Items) == 0:
		lv.Empty = "Could not load " + noun + "s; the reason is in the footer."
	}
	frame := lv.frame(brand("albedo")+" "+DefaultStyles.Muted.Render("/"+m.Kind), "", m.footer(width))
	if m.Form != nil {
		frame.filter, frame.pane, frame.list = "", nil, m.formList
	} else {
		frame.summary = m.summary()
	}
	return frame.view(m.Width, m.Height)
}

func capabilityChoiceID(item capabilityItem, scope string) string {
	if scope == scopeGlobal {
		return item.Candidate.ID
	}
	return item.ID
}

func (m CapabilityPageModel) storedSecrets(name string) daemon.MCPSecretNames {
	if item, ok := m.itemNamed(name); ok {
		return item.Secrets
	}
	return daemon.MCPSecretNames{}
}
