package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"slices"
	"strings"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// WebhooksPageModel is the Webhooks screen: every signed endpoint grouped by
// the session it wakes, their inboxes, and whether the agent of the session it
// was opened from may manage its own. Every change runs /webhooks on the
// daemon and then reloads, so the list is never patched locally.
type WebhooksPageModel struct {
	Conn      *daemon.Connection
	SessionID string
	// Sessions are the ones a hook can target, the current one first.
	Sessions        []daemon.Session
	Hooks           []webhookEntry
	AgentManagement bool
	// Mounted reports whether the extension is on globally; the daemon only
	// listens for deliveries then.
	Mounted bool
	Loaded  bool
	Confirm string // "delete" or "rotate"
	Form    *webhookForm
	// Reveal holds a generated secret until it is dismissed; it is never
	// fetched again.
	Reveal *webhookSecret
	page
}

type webhookEntry struct {
	ID       string
	Session  string
	Name     string
	Enabled  bool
	URL      string
	Header   string
	Prefix   string
	Queued   int
	Deferred string
}

type webhookSecret struct{ Hook, Session, Secret string }

type webhooksLoadedMsg struct {
	Sessions []daemon.Session
	Hooks    []webhookEntry
	Agent    bool
	Mounted  bool
	Gen      int
	Err      error
}

type webhooksSavedMsg struct {
	Notice string
	Reveal *webhookSecret
	Gen    int
	Err    error
}

type WebhooksPageDoneMsg struct{}
type ChatOpenWebhooksPageMsg struct{}

const (
	defaultSignatureHeader = "x-albedo-signature"
	defaultSignaturePrefix = "sha256="
)

func NewWebhooksPageModel(conn *daemon.Connection, sessionID string) WebhooksPageModel {
	return WebhooksPageModel{Conn: conn, SessionID: sessionID, Mounted: true, page: page{Loading: true}}
}

func (m WebhooksPageModel) Init() tea.Cmd { return m.loadCmd(m.Generation) }

// run calls /webhooks with an action and answers its result object.
func (m WebhooksPageModel) run(action, details string) (map[string]any, error) {
	if m.Conn == nil {
		return nil, errors.New("daemon connection unavailable")
	}
	path := fmt.Sprintf("/sessions/%s/commands", url.PathEscape(m.SessionID))
	body := map[string]any{"name": "/webhooks", "args": map[string]string{"action": action, "details": details}}
	res, err := daemon.Request[map[string]any](context.Background(), m.Conn, path, body)
	if err != nil {
		return nil, err
	}
	if r, ok := res["result"].(map[string]any); ok {
		return r, nil
	}
	return res, nil
}

func (m WebhooksPageModel) loadCmd(gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return webhooksLoadedMsg{Gen: gen, Err: errors.New("daemon connection unavailable")}
		}
		mounted := true
		path := fmt.Sprintf("/sessions/%s/extensions", url.PathEscape(m.SessionID))
		if extensions, err := daemon.Request[[]ExtensionItem](context.Background(), m.Conn, path, nil); err == nil {
			if i := slices.IndexFunc(extensions, func(ext ExtensionItem) bool { return ext.Name == "webhooks" }); i >= 0 {
				mounted = extensions[i].GlobalEnabled
				if !extensions[i].Enabled {
					return webhooksLoadedMsg{Gen: gen, Err: errors.New("webhooks are off for this session; turn them on in /extensions")}
				}
			}
		}
		all, err := daemon.Request[[]daemon.Session](context.Background(), m.Conn, "/sessions", nil)
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
		res, err := m.run("list", "")
		if err != nil {
			return webhooksLoadedMsg{Gen: gen, Err: err}
		}
		agent, _ := res["agentManagement"].(bool)
		var hooks []webhookEntry
		entries, _ := res["hooks"].([]any)
		for _, raw := range entries {
			entry, _ := raw.(map[string]any)
			hook, _ := entry["hook"].(map[string]any)
			if hook == nil {
				continue
			}
			queued, _ := entry["queued"].(float64)
			enabled, _ := hook["enabled"].(bool)
			w := webhookEntry{
				ID:       str(hook, "id"),
				Session:  str(hook, "session"),
				Name:     str(hook, "name"),
				URL:      str(hook, "url"),
				Header:   str(hook, "signatureHeader"),
				Prefix:   str(hook, "signaturePrefix"),
				Enabled:  enabled,
				Queued:   int(queued),
				Deferred: str(entry, "deferred"),
			}
			if w.ID != "" {
				hooks = append(hooks, w)
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
		return webhooksLoadedMsg{Sessions: sessions, Hooks: hooks, Agent: agent, Mounted: mounted, Gen: gen}
	}
}

// newHookID stands in for the id of a hook created by an earlier step.
const newHookID = "{id}"

// save runs steps in order and stops at the first failure; a generated secret
// from any step is carried back to be shown once.
func (m WebhooksPageModel) save(gen int, notice string, steps ...[2]string) tea.Cmd {
	return func() tea.Msg {
		var reveal *webhookSecret
		created := ""
		for _, step := range steps {
			res, err := m.run(step[0], strings.Replace(step[1], newHookID, created, 1))
			if err != nil {
				// The hook exists with this secret even though a later step
				// failed, so it still has to be shown.
				return webhooksSavedMsg{Reveal: reveal, Gen: gen, Err: err}
			}
			hook, _ := res["hook"].(map[string]any)
			if id, ok := hook["id"].(string); ok {
				created = id
			}
			if secret, _ := res["secret"].(string); secret != "" {
				name, _ := hook["name"].(string)
				session, _ := hook["session"].(string)
				reveal = &webhookSecret{Hook: name, Session: session, Secret: secret}
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

// address is where a sender posts: the daemon's local address, which a
// reverse proxy can expose.
func (m WebhooksPageModel) address(hook webhookEntry) string {
	if m.Conn == nil || m.Conn.Port() == 0 {
		return hook.URL
	}
	return fmt.Sprintf("http://127.0.0.1:%d%s", m.Conn.Port(), hook.URL)
}

func (m WebhooksPageModel) begin(notice string, steps ...[2]string) (WebhooksPageModel, tea.Cmd) {
	m.Error, m.Notice = "", ""
	m.Saving = true
	m.Generation++
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
		m.Sessions, m.Hooks, m.AgentManagement, m.Mounted = msg.Sessions, msg.Hooks, msg.Agent, msg.Mounted
		return m, nil
	case webhooksSavedMsg:
		if msg.Gen != m.Generation {
			return m, nil
		}
		m.Saving, m.Reveal = false, msg.Reveal
		if msg.Err != nil {
			m.Error = msg.Err.Error()
			if msg.Reveal == nil {
				return m, nil
			}
		} else {
			m.Form, m.Notice = nil, msg.Notice
		}
		m.Loading, m.Generation = true, m.Generation+1
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
			return m.begin(note, [2]string{action, hook.ID})
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
			m.Generation++
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
				return m.begin(note, [2]string{action, hook.ID})
			}
		case "n":
			m.Error, m.Notice = "", ""
			m.Form = newWebhookForm(nil, m.Sessions, m.SessionID)
		case "a":
			action, note := "agent_on", "This session’s agent can now manage its own webhooks."
			if m.AgentManagement {
				action, note = "agent_off", "This session’s agent can no longer manage its webhooks."
			}
			return m.begin(note, [2]string{action, ""})
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
				return m, CopyText(m.address(*hook))
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

func (m WebhooksPageModel) View() string {
	width := max(1, m.Width)
	rows := m.header("/webhooks", "all sessions")
	if m.Loading && !m.Loaded {
		rows = append(rows, DefaultStyles.Faint.Render("loading webhooks…"))
		return strings.Join(rows, "\n")
	}
	if !m.Loaded {
		return strings.Join(append(rows, "", keyHints(hint{"r", "retry"}, hint{"esc", "back"})), "\n")
	}
	// Give the confirmation the screen instead of truncating its consequence or target.
	if m.Confirm != "" && m.selected() != nil {
		question := "Its URL will stop working; accepted deliveries stay in the inbox. Delete " + m.selected().Name + "?"
		if m.Confirm == "rotate" {
			question = "The sender must use the new secret. Replace the secret for " + m.selected().Name + "?"
		}
		rows = append(rows, "")
		for line := range strings.SplitSeq(ansi.Wrap(question, width, " "), "\n") {
			rows = append(rows, DefaultStyles.Warning.Render(line))
		}
		rows = append(rows, keyHints(hint{"enter", "confirm"}, hint{"any other key", "cancels"}))
		return m.fit(rows)
	}
	if !m.Mounted {
		rows = append(rows, DefaultStyles.Warning.Render("Webhooks are not listening")+DefaultStyles.Faint.Render(" · enable webhooks globally in /extensions to accept deliveries"))
	}
	agent := DefaultStyles.Faint.Render("off") + DefaultStyles.Faint.Render(" · this session's agent can't touch webhooks")
	if m.AgentManagement {
		agent = DefaultStyles.Success.Render("on ") + DefaultStyles.Faint.Render(" · this session's agent can add, rotate and delete its own hooks")
	}
	rows = append(rows, ansi.Truncate(DefaultStyles.Muted.Render("agent access ")+agent, width, "…"), "")

	if len(m.Hooks) == 0 {
		rows = append(rows, DefaultStyles.Faint.Render("No webhooks yet. Add one to wake a session with a signed request."))
	}
	nameWidth := 4
	for _, hook := range m.Hooks {
		nameWidth = max(nameWidth, ansi.StringWidth(hook.Name))
	}
	// Hooks sit under the session they wake; the cursor line is kept in view.
	counts := map[string]int{}
	for _, hook := range m.Hooks {
		counts[hook.Session]++
	}
	var list []string
	cursorLine := 0
	for i, hook := range m.Hooks {
		if i == 0 || hook.Session != m.Hooks[i-1].Session {
			if i > 0 {
				list = append(list, "")
			}
			list = append(list, sectionRule(ansi.Truncate(sessionLabel(m.Sessions, hook.Session, m.SessionID), max(8, width-12), "…"), counts[hook.Session], width))
		}
		var label string
		if hook.Enabled {
			label = DefaultStyles.Success.Render("on ")
		} else {
			label = DefaultStyles.Faint.Render("off")
		}
		row := label + "  " + padRight(hook.Name, nameWidth+1) + DefaultStyles.Faint.Render(hook.URL)
		if hook.Queued > 0 {
			row += DefaultStyles.Decor.Render(" · ") + DefaultStyles.Warning.Render(fmt.Sprintf("%d queued", hook.Queued))
		}
		if i == m.Cursor {
			cursorLine = len(list)
		}
		list = append(list, listRow(i == m.Cursor, row, width))
	}
	rows = append(rows, scrolled(list, cursorLine, max(2, m.Height-17))...)

	switch {
	case m.Reveal != nil:
		rows = append(rows, "", ansi.Truncate(DefaultStyles.Bold.Render("signing secret for "+m.Reveal.Hook)+DefaultStyles.Faint.Render(" → "+sessionLabel(m.Sessions, m.Reveal.Session, m.SessionID)+" · shown only once; copy it now"), width, "…"))
		rows = append(rows, "  "+DefaultStyles.Prompt.Render(m.Reveal.Secret), "")
		rows = append(rows, keyHints(hint{"c", "copy"}, hint{"enter", "done"}))
	case m.Form != nil:
		rows = append(rows, "")
		rows = append(rows, m.Form.view(width)...)
		if m.Saving {
			rows = append(rows, DefaultStyles.Faint.Render("saving…"))
		}
	case m.Saving:
		rows = append(rows, "", DefaultStyles.Faint.Render("saving…"))
	default:
		if hook := m.selected(); hook != nil {
			rows = append(rows, "")
			rows = append(rows, m.detail(*hook, width)...)
		}
		browse := []hint{{"r", "refresh"}, {"esc", "back"}}
		keys := []hint{{"n", "add hook"}, {"a", "agent access"}}
		if len(m.Hooks) > 0 {
			browse = []hint{{"↑↓", "select"}, {"space", "on/off"}, {"y", "copy url"}, {"r", "refresh"}, {"esc", "back"}}
			keys = []hint{{"n", "add hook"}, {"enter", "edit"}, {"k", "new secret"}, {"d", "delete"}, {"a", "agent access"}}
		}
		rows = append(rows, "", keyHints(browse...), keyHints(keys...))
	}
	return m.fit(rows)
}

// detail explains the selected hook: where to send, how to sign, and what is
// waiting for the session.
func (m WebhooksPageModel) detail(hook webhookEntry, width int) []string {
	field := func(label, value string) string {
		return ansi.Truncate(DefaultStyles.Muted.Render(padRight(label, 11))+value, width, "…")
	}
	rows := []string{
		field("wakes", sessionLabel(m.Sessions, hook.Session, m.SessionID)),
		field("url", "POST "+m.address(hook)),
		field("signature", hook.Header+": "+hook.Prefix+DefaultStyles.Faint.Render("<hex HMAC-SHA256 of the body>")),
	}
	inbox := DefaultStyles.Faint.Render("empty")
	if hook.Queued > 0 {
		inbox = DefaultStyles.Warning.Render(fmt.Sprintf("%d waiting for the session", hook.Queued))
		if hook.Deferred != "" {
			inbox += DefaultStyles.Faint.Render(" · last attempt: " + hook.Deferred)
		}
	}
	if !hook.Enabled {
		inbox += DefaultStyles.Faint.Render(" · off, new deliveries answer 404")
	}
	return append(rows, field("inbox", inbox))
}

// webhookForm adds a hook or edits one on a single screen: the session it
// wakes, its name, signing secret, and the header and prefix its sender signs
// with. The session and name are fixed once the hook exists.
type webhookForm struct {
	// Editing is the hook being edited; nil for a new hook.
	Editing *webhookEntry
	form
	// Sessions are offered in order; Chosen starts at Current, the session
	// the screen was opened from.
	Sessions        []daemon.Session
	Current, Chosen string
}

const (
	hookFieldSession = "session"
	hookFieldName    = "name"
	hookFieldSecret  = "secret"
	hookFieldHeader  = "header"
	hookFieldPrefix  = "prefix"
)

var hookFields = []string{hookFieldSession, hookFieldName, hookFieldSecret, hookFieldHeader, hookFieldPrefix}

// sessionChoices is how many matching sessions the picker shows at once.
const sessionChoices = 5

var (
	hookName   = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
	hookHeader = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`)
)

func newWebhookForm(editing *webhookEntry, sessions []daemon.Session, current string) *webhookForm {
	f := &webhookForm{form: newForm(hookFields, hookFieldSecret), Sessions: sessions, Current: current, Chosen: current}
	f.Inputs[hookFieldSession].Placeholder = "type to filter"
	f.Inputs[hookFieldName].Placeholder = "github-deploys"
	f.Inputs[hookFieldHeader].SetValue(defaultSignatureHeader)
	f.Inputs[hookFieldPrefix].SetValue(defaultSignaturePrefix)
	f.Inputs[hookFieldSecret].Placeholder = "leave blank to generate one"
	f.Focus = 1 // the session already defaults to this one
	if editing != nil {
		hook := *editing
		f.Editing, f.Chosen, f.Focus = &hook, hook.Session, 2
		f.Inputs[hookFieldName].SetValue(hook.Name)
		f.Inputs[hookFieldHeader].SetValue(hook.Header)
		f.Inputs[hookFieldPrefix].SetValue(hook.Prefix)
		f.Inputs[hookFieldSecret].Placeholder = "stored · leave blank to keep it"
	}
	f.focus(f.current())
	return f
}

func (f *webhookForm) current() string { return hookFields[f.Focus] }

// matches are the sessions the picker's filter leaves, in order.
func (f *webhookForm) matches() []daemon.Session {
	query := strings.ToLower(strings.TrimSpace(f.Inputs[hookFieldSession].Value()))
	var out []daemon.Session
	for _, s := range f.Sessions {
		if query == "" || strings.Contains(strings.ToLower(sessionTitle(s)+" "+homePath(s.Workspace)+" "+s.ID), query) {
			out = append(out, s)
		}
	}
	return out
}

func (f *webhookForm) chosenIndex(matches []daemon.Session) int {
	return slices.IndexFunc(matches, func(s daemon.Session) bool { return s.ID == f.Chosen })
}

// update handles one key or paste; submit reports that the form should be saved.
func (f *webhookForm) update(msg tea.Msg) (submit bool, cmd tea.Cmd) {
	firstField := 0
	if f.Editing != nil {
		firstField = 2
	}
	if submit, handled := f.key(msg, hookFields, firstField); handled {
		return submit, nil
	}
	if key, ok := msg.(tea.KeyPressMsg); ok {
		if f.current() == hookFieldSession && (key.String() == "left" || key.String() == "right") {
			if matches := f.matches(); len(matches) > 0 {
				i := f.chosenIndex(matches)
				if i < 0 {
					i = 0
				} else {
					step := 1
					if key.String() == "left" {
						step = -1
					}
					i = (i + step + len(matches)) % len(matches)
				}
				f.Chosen = matches[i].ID
				return false, nil
			}
		}
	}
	input := f.Inputs[f.current()]
	next, cmd := input.Update(msg)
	*input = next
	if f.current() == hookFieldSession {
		if matches := f.matches(); len(matches) > 0 && f.chosenIndex(matches) < 0 {
			f.Chosen = matches[0].ID
		}
	}
	return false, cmd
}

// steps turns the form into /webhooks calls, after checking what the daemon
// would otherwise reject one step in.
func (f *webhookForm) steps() ([][2]string, string, error) {
	name, secret, header, prefix := f.value(hookFieldName), f.value(hookFieldSecret), f.value(hookFieldHeader), f.value(hookFieldPrefix)
	switch {
	case f.Editing == nil && f.Chosen == "":
		return nil, "", errors.New("choose the session this webhook will wake")
	case f.Editing == nil && !hookName.MatchString(name):
		return nil, "", errors.New("use 1–64 letters, digits, underscores, or hyphens for the webhook name")
	case secret != "" && (len(secret) < 16 || len(secret) > 4096):
		if f.Editing != nil {
			return nil, "", errors.New("use 16–4096 bytes for the secret, or leave it blank to keep the existing secret")
		}
		return nil, "", errors.New("use 16–4096 bytes for the secret, or leave it blank to generate one")
	case strings.ContainsAny(secret, " \t"):
		return nil, "", errors.New("remove spaces from the secret")
	case !hookHeader.MatchString(header):
		return nil, "", errors.New("use 1–64 letters, digits, or hyphens for the signature header")
	case len(prefix) > 32 || strings.ContainsAny(prefix, " \t"):
		return nil, "", errors.New("use at most 32 characters without spaces for the signature prefix")
	}
	if f.Editing == nil {
		create := f.Chosen + " " + name
		if secret != "" {
			create += " " + secret
		}
		steps := [][2]string{{"create_in", create}}
		if !strings.EqualFold(header, defaultSignatureHeader) || prefix != defaultSignaturePrefix {
			steps = append(steps, [2]string{"signature", newHookID + " " + header + " " + prefix})
		}
		return steps, "added " + name + " · wakes " + sessionLabel(f.Sessions, f.Chosen, f.Current), nil
	}
	var steps [][2]string
	if !strings.EqualFold(header, f.Editing.Header) || prefix != f.Editing.Prefix {
		steps = append(steps, [2]string{"signature", f.Editing.ID + " " + header + " " + prefix})
	}
	if secret != "" {
		steps = append(steps, [2]string{"rotate_with_secret", f.Editing.ID + " " + secret})
	}
	return steps, "saved " + f.Editing.Name, nil
}

func (f *webhookForm) view(width int) []string {
	title := "add webhook"
	if f.Editing != nil {
		title = "edit " + f.Editing.Name
	}
	f.fit(width - 14)
	rows := []string{DefaultStyles.Bold.Render(title)}
	indent := strings.Repeat(" ", 13)
	for i, key := range hookFields {
		value := f.Inputs[key].View()
		switch {
		case key == hookFieldSession && f.Editing != nil:
			value = DefaultStyles.Faint.Render(sessionLabel(f.Sessions, f.Chosen, f.Current))
		case key == hookFieldSession && i != f.Focus:
			value = sessionLabel(f.Sessions, f.Chosen, f.Current)
		case key == hookFieldName && f.Editing != nil:
			value = DefaultStyles.Faint.Render(f.Editing.Name)
		}
		rows = append(rows, formRow(i == f.Focus, key, 11, value, width))
		if key == hookFieldSession && i == f.Focus {
			rows = append(rows, f.pickerRows(indent, width)...)
		}
	}
	var own []hint
	var note string
	switch f.current() {
	case hookFieldSession:
		note, own = "which session deliveries wake", []hint{{"←→", "choose"}}
	case hookFieldName:
		note = "letters, digits, _ or -"
	case hookFieldSecret:
		note = "16+ bytes from the sender, or blank to generate one"
		if f.Editing != nil {
			note = "enter a new secret to replace the stored one"
		}
	case hookFieldHeader:
		note = "the header the sender signs with · GitHub uses x-hub-signature-256"
	case hookFieldPrefix:
		note = "text before the hex digest · blank for none"
	}
	return append(rows, "", formFooter(note, width, own...))
}

// pickerRows lists the matching sessions around the chosen one.
func (f *webhookForm) pickerRows(indent string, width int) []string {
	matches := f.matches()
	if len(matches) == 0 {
		return []string{indent + DefaultStyles.Faint.Render("No sessions match. Try another search.")}
	}
	chosen := max(0, f.chosenIndex(matches))
	start := max(0, min(chosen-sessionChoices/2, len(matches)-sessionChoices))
	var rows []string
	w := width - len(indent)
	for i := start; i < min(len(matches), start+sessionChoices); i++ {
		label := sessionLabel(f.Sessions, matches[i].ID, f.Current)
		if i == chosen {
			rows = append(rows, indent+selectedLine(ansi.Truncate(selectBar()+" "+label, w, "…"), w))
		} else {
			rows = append(rows, indent+DefaultStyles.Faint.Render(ansi.Truncate("  "+label, w, "…")))
		}
	}
	if more := len(matches) - sessionChoices; more > 0 {
		rows = append(rows, indent+DefaultStyles.Faint.Render(fmt.Sprintf("  %d more · type to filter", more)))
	}
	return rows
}
