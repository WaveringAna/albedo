package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"errors"
	"slices"
	"strings"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// WebhooksPageModel is the Webhooks screen: every signed endpoint grouped by
// the session it wakes, their inboxes, and whether the agent of the session it
// was opened from may manage its own. Changes use the typed webhook API and
// reload the list after saving.
type WebhooksPageModel struct {
	Conn *daemon.Connection
	Form *webhookForm
	// Reveal holds a generated secret until it is dismissed; it is never
	// fetched again.
	Reveal         *webhookSecret
	SessionID      string
	PermissionETag string
	Confirm        string // "delete" or "rotate"
	// Sessions are the ones a hook can target, the current one first.
	Sessions []daemon.Session
	Hooks    []webhookEntry
	page
	AgentManagement bool
	// Mounted reports whether the extension is on globally; the daemon only
	// listens for deliveries then.
	Mounted bool
	Loaded  bool
}

type webhookEntry struct {
	ETag     string
	ID       string
	Session  string
	Name     string
	Address  string
	URL      string
	Header   string
	Prefix   string
	Deferred string
	Queued   int
	Enabled  bool
}

type webhookSecret struct{ Hook, Session, Secret string }

type webhooksLoadedMsg struct {
	PermissionETag string
	Err            error
	Sessions       []daemon.Session
	Hooks          []webhookEntry
	Gen            int
	Agent          bool
	Mounted        bool
}

type webhooksSavedMsg struct {
	Err    error
	Reveal *webhookSecret
	Notice string
	Gen    int
}

type WebhooksPageDoneMsg struct{}
type ChatOpenWebhooksPageMsg struct{}

const (
	defaultSignatureHeader = "x-albedo-signature"
	defaultSignaturePrefix = "sha256="
)

func NewWebhooksPageModel(conn *daemon.Connection, sessionID string) WebhooksPageModel {
	return WebhooksPageModel{Conn: conn, SessionID: sessionID, Mounted: true, page: page{Loading: true, Generation: nextPageGeneration()}}
}

func (m WebhooksPageModel) Init() tea.Cmd { return m.loadCmd(m.Generation) }

func (m WebhooksPageModel) loadCmd(gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return webhooksLoadedMsg{Gen: gen, Err: errors.New("daemon connection unavailable")}
		}
		mounted := true
		extensions, err := daemon.ListExtensions(context.Background(), m.Conn, m.SessionID)
		if err != nil {
			return webhooksLoadedMsg{Gen: gen, Err: err}
		}
		if i := slices.IndexFunc(extensions, func(ext ExtensionItem) bool { return ext.Name == "webhooks" }); i >= 0 {
			mounted = extensions[i].GlobalEnabled
			if !extensions[i].Enabled {
				return webhooksLoadedMsg{Gen: gen, Err: errors.New("webhooks are off for this session; turn them on in /extensions")}
			}
		}
		all, err := daemon.ListAllSessions(context.Background(), m.Conn)
		if err != nil {
			return webhooksLoadedMsg{Gen: gen, Err: err}
		}
		var sessions []daemon.Session
		for _, s := range all {
			if s.ID == m.SessionID {
				sessions = slices.Insert(sessions, 0, s)
			} else {
				sessions = append(sessions, s)
			}
		}
		rows, err := daemon.ListWebhooks(context.Background(), m.Conn, "")
		if err != nil {
			return webhooksLoadedMsg{Gen: gen, Err: err}
		}
		permission, err := daemon.GetWebhookPermission(context.Background(), m.Conn, m.SessionID)
		if err != nil {
			return webhooksLoadedMsg{Gen: gen, Err: err}
		}
		agent := permission.AgentManagement
		hooks := make([]webhookEntry, len(rows))
		for i, entry := range rows {
			hook := entry.Hook
			deferred := ""
			if entry.Deferred != nil {
				deferred = *entry.Deferred
			}
			hooks[i] = webhookEntry{
				ETag: hook.ETag, ID: hook.ID, Session: hook.Session, Name: hook.Name, URL: hook.URL, Address: hook.Address,
				Header: hook.Header, Prefix: hook.Prefix, Enabled: hook.Enabled,
				Queued: entry.Queued, Deferred: deferred,
			}
		}
		// Group by session in the order they are offered, current first.
		rank := func(id string) int {
			if i := slices.IndexFunc(sessions, func(s daemon.Session) bool { return s.ID == id }); i >= 0 {
				return i
			}
			return len(sessions)
		}
		slices.SortStableFunc(hooks, func(a, b webhookEntry) int { return cmp.Compare(rank(a.Session), rank(b.Session)) })
		return webhooksLoadedMsg{Sessions: sessions, Hooks: hooks, Agent: agent, Mounted: mounted, PermissionETag: permission.ETag, Gen: gen}
	}
}

// save runs steps in order and stops at the first failure; a generated secret
// from any step is carried back to be shown once.
func (m WebhooksPageModel) save(gen int, notice string, steps ...daemon.WebhookRequest) tea.Cmd {
	return func() tea.Msg {
		var reveal *webhookSecret
		created, etag := "", ""
		for _, step := range steps {
			if step.HookID == "" {
				step.HookID = created
			}
			if etag != "" && step.HookID == created {
				step.ETag = etag
			}
			var res *daemon.WebhookResult
			var err error
			switch step.Action {
			case daemon.WebhookCreate:
				res, err = daemon.CreateWebhook(context.Background(), m.Conn, daemon.WebhookCreateRequest{SessionID: step.SessionID, Name: step.Name, Secret: step.Secret, Header: step.Header, Prefix: &step.Prefix})
			case daemon.WebhookSignature:
				res, err = daemon.EditWebhook(context.Background(), m.Conn, step.HookID, step.ETag, daemon.WebhookPatch{Header: &step.Header, Prefix: &step.Prefix})
			case daemon.WebhookRotate:
				res, err = daemon.RotateWebhookSecret(context.Background(), m.Conn, step.HookID, step.ETag, step.Secret)
			case daemon.WebhookEnable, daemon.WebhookDisable:
				enabled := step.Action == daemon.WebhookEnable
				res, err = daemon.EditWebhook(context.Background(), m.Conn, step.HookID, step.ETag, daemon.WebhookPatch{Enabled: &enabled})
			case daemon.WebhookDelete:
				res, err = daemon.DeleteWebhook(context.Background(), m.Conn, step.HookID, step.ETag)
			case daemon.WebhookAgentEnable, daemon.WebhookAgentDisable:
				res, err = daemon.SetWebhookPermission(context.Background(), m.Conn, m.SessionID, step.ETag, step.Action == daemon.WebhookAgentEnable)
			default:
				err = errors.New("unknown webhook form action")
			}
			if err != nil {
				// The hook exists with this secret even though a later step
				// failed, so it still has to be shown.
				return webhooksSavedMsg{Reveal: reveal, Gen: gen, Err: err}
			}
			if res.Message != "" {
				notice = res.Message
			}
			if res.Hook != nil {
				created, etag = res.Hook.ID, res.Hook.ETag
				if res.Secret != "" {
					reveal = &webhookSecret{Hook: res.Hook.Name, Session: res.Hook.Session, Secret: res.Secret}
				}
			}
		}
		return webhooksSavedMsg{Notice: notice, Reveal: reveal, Gen: gen}
	}
}

func (m WebhooksPageModel) selected() *webhookEntry {
	if m.Cursor < len(m.Hooks) {
		return &m.Hooks[m.Cursor]
	}
	return nil
}

// sessionLabel names a session plainly enough to tell it apart from the
// others. Whether it is the session this screen was opened from comes first,
// and the title is capped, so a long title never hides the rest.
func sessionLabel(sessions []daemon.Session, id, current string) string {
	parts := []string{"session " + id[:min(8, len(id))]}
	if i := slices.IndexFunc(sessions, func(s daemon.Session) bool { return s.ID == id }); i >= 0 {
		s := sessions[i]
		parts = []string{ansi.Truncate(sessionTitle(s), 32, "…")}
		if s.Workspace != "" {
			parts = append(parts, homePath(s.Workspace))
		}
	}
	if id == current {
		parts = append([]string{"this session"}, parts...)
	}
	return strings.Join(parts, " · ")
}

func (m WebhooksPageModel) begin(notice string, steps ...daemon.WebhookRequest) (WebhooksPageModel, tea.Cmd) {
	for i := range steps {
		if steps[i].Action == daemon.WebhookAgentEnable || steps[i].Action == daemon.WebhookAgentDisable {
			steps[i].ETag = m.PermissionETag
		} else {
			for _, hook := range m.Hooks {
				if hook.ID == steps[i].HookID {
					steps[i].ETag = hook.ETag
				}
			}
		}
	}
	m.Error, m.Notice = "", ""
	m.Saving = true
	m.Generation = nextPageGeneration()
	return m, m.save(m.Generation, notice, steps...)
}

func (m WebhooksPageModel) Update(msg tea.Msg) (WebhooksPageModel, tea.Cmd) {
	switch msg := msg.(type) {
	case webhooksLoadedMsg:
		if !m.settle(msg.Gen, msg.Err, &m.Loading) {
			return m, nil
		}
		m.Loaded = true
		m.Cursor = reselect(m.Cursor, m.Hooks, msg.Hooks, func(hook webhookEntry) string { return hook.ID })
		m.PermissionETag = msg.PermissionETag
		m.Sessions, m.Hooks, m.AgentManagement, m.Mounted = msg.Sessions, msg.Hooks, msg.Agent, msg.Mounted
		return m, nil
	case webhooksSavedMsg:
		if msg.Gen != m.Generation {
			return m, nil
		}
		m.Saving, m.Reveal = false, msg.Reveal
		if msg.Err != nil {
			m.Error = msg.Err.Error()
			if _, uncertain := errors.AsType[*daemon.UncertainOutcomeError](msg.Err); uncertain {
				return m, nil
			}
			if msg.Reveal == nil {
				return m, nil
			}
		} else {
			m.Form, m.Notice = nil, msg.Notice
		}
		m.Loading, m.Generation = true, nextPageGeneration()
		return m, m.loadCmd(m.Generation)
	case tea.KeyPressMsg:
		key := msg.String()
		if m.Saving {
			return m, nil
		}
		if m.Reveal != nil {
			switch key {
			case "c":
				m.Error, m.Notice = "", "Secret copied."
				return m, CopyText(m.Reveal.Secret)
			case "enter", "esc":
				m.Reveal = nil
			}
			return m, nil
		}
		if m.Form != nil {
			if key == "esc" {
				m.Form = nil
				m.Error = ""
				return m, nil
			}
			submit, cmd := m.Form.update(msg)
			if !submit {
				return m, cmd
			}
			steps, notice, err := m.Form.steps()
			if err != nil {
				m.Error = err.Error()
				return m, nil
			}
			if len(steps) == 0 {
				m.Form = nil
				m.Error, m.Notice = "", "No changes made."
				return m, nil
			}
			return m.begin(notice, steps...)
		}
		if m.Confirm != "" {
			action := m.Confirm
			m.Confirm = ""
			hook := m.selected()
			if key != "enter" || hook == nil {
				return m, nil
			}
			note := "New secret for " + hook.Name
			if action == "delete" {
				note = "Deleted " + hook.Name
			}
			return m.begin(note, daemon.WebhookRequest{Action: daemon.WebhookAction(action), HookID: hook.ID})
		}
		if key == "esc" || key == "ctrl+c" {
			return m, func() tea.Msg { return WebhooksPageDoneMsg{} }
		}
		if m.Loading {
			return m, nil
		}
		if key == "r" {
			m.Error, m.Notice = "", ""
			m.Loading = true
			m.Generation = nextPageGeneration()
			return m, m.loadCmd(m.Generation)
		}
		if !m.Loaded {
			return m, nil
		}
		if m.step(key, len(m.Hooks)) {
			return m, nil
		}
		hook := m.selected()
		switch key {
		case "enter":
			if hook != nil {
				m.Error, m.Notice = "", ""
				m.Form = newWebhookForm(hook, m.Sessions, m.SessionID)
			}
		case "space":
			if hook != nil {
				action, note := "enable", hook.Name+" enabled."
				if hook.Enabled {
					action, note = "disable", hook.Name+" disabled. New deliveries will receive a 404 response."
				}
				return m.begin(note, daemon.WebhookRequest{Action: daemon.WebhookAction(action), HookID: hook.ID})
			}
		case "n":
			m.Error, m.Notice = "", ""
			m.Form = newWebhookForm(nil, m.Sessions, m.SessionID)
		case "a":
			action, note := daemon.WebhookAgentEnable, "This session’s agent can now manage its own webhooks."
			if m.AgentManagement {
				action, note = daemon.WebhookAgentDisable, "This session’s agent can no longer manage its webhooks."
			}
			return m.begin(note, daemon.WebhookRequest{Action: action})
		case "d", "k":
			if hook != nil {
				if key == "d" {
					m.Confirm = "delete"
				} else {
					m.Confirm = "rotate"
				}
			}
		case "y":
			if hook != nil {
				m.Error, m.Notice = "", "URL copied."
				return m, CopyText(cmp.Or(hook.Address, hook.URL))
			}
		}
	case tea.PasteMsg:
		if m.Saving || m.Reveal != nil || m.Form == nil {
			return m, nil
		}
		_, cmd := m.Form.update(msg)
		return m, cmd
	}
	return m, nil
}
