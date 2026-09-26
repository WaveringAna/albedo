package tui

import (
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"sort"
	"strings"

	"charm.land/bubbles/v2/textinput"
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
	Mounted                           bool
	Cursor, Width, Height, Generation int
	Loaded, Loading, Saving           bool
	Confirm                           string // "delete" or "rotate"
	Form                              *webhookForm
	// Reveal holds a generated secret until it is dismissed; it is never
	// fetched again.
	Reveal        *webhookSecret
	Error, Notice string
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
	return WebhooksPageModel{Conn: conn, SessionID: sessionID, Loading: true, Mounted: true}
}

func (m *WebhooksPageModel) SetSize(w, h int) {
	m.Width = w
	m.Height = h
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
		mounted := true
		if m.Conn != nil {
			path := fmt.Sprintf("/sessions/%s/extensions", url.PathEscape(m.SessionID))
			if extensions, err := daemon.Request[[]ExtensionItem](context.Background(), m.Conn, path, nil); err == nil {
				for _, ext := range extensions {
					if ext.Name == "webhooks" {
						mounted = ext.GlobalEnabled
						if !ext.Enabled {
							return webhooksLoadedMsg{Gen: gen, Err: errors.New("the webhooks extension is off for this session · turn it on in /extensions")}
						}
					}
				}
			}
		}
		var sessions []daemon.Session
		if m.Conn != nil {
			all, err := daemon.Request[[]daemon.Session](context.Background(), m.Conn, "/sessions", nil)
			if err != nil {
				return webhooksLoadedMsg{Gen: gen, Err: err}
			}
			for _, s := range all {
				if s.ID == m.SessionID {
					sessions = append([]daemon.Session{s}, sessions...)
				} else {
					sessions = append(sessions, s)
				}
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
			hook, ok := entry["hook"].(map[string]any)
			if !ok {
				continue
			}
			w := webhookEntry{}
			w.ID, _ = hook["id"].(string)
			w.Session, _ = hook["session"].(string)
			w.Name, _ = hook["name"].(string)
			w.Enabled, _ = hook["enabled"].(bool)
			w.URL, _ = hook["url"].(string)
			w.Header, _ = hook["signatureHeader"].(string)
			w.Prefix, _ = hook["signaturePrefix"].(string)
			if queued, ok := entry["queued"].(float64); ok {
				w.Queued = int(queued)
			}
			w.Deferred, _ = entry["deferred"].(string)
			if w.ID != "" {
				hooks = append(hooks, w)
			}
		}
		// Group by session in the order they are offered, current first.
		order := map[string]int{}
		for i, s := range sessions {
			order[s.ID] = i
		}
		rank := func(id string) int {
			if i, ok := order[id]; ok {
				return i
			}
			return len(sessions)
		}
		sort.SliceStable(hooks, func(i, j int) bool { return rank(hooks[i].Session) < rank(hooks[j].Session) })
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
				if reveal != nil {
					// The hook exists with this secret even though a later step
					// failed, so it still has to be shown.
					return webhooksSavedMsg{Reveal: reveal, Gen: gen, Err: err}
				}
				return webhooksSavedMsg{Gen: gen, Err: err}
			}
			hook, _ := res["hook"].(map[string]any)
			if id, ok := hook["id"].(string); ok {
				created = id
			}
			if secret, ok := res["secret"].(string); ok && secret != "" {
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
	for _, s := range sessions {
		if s.ID == id {
			parts = []string{ansi.Truncate(sessionTitle(s), 32, "…")}
			if s.Workspace != "" {
				parts = append(parts, homePath(s.Workspace))
			}
			break
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
		if msg.Gen != m.Generation {
			return m, nil
		}
		m.Loading = false
		if msg.Err != nil {
			m.Error = msg.Err.Error()
			return m, nil
		}
		selected := ""
		if hook := m.selected(); hook != nil {
			selected = hook.ID
		}
		m.Loaded = true
		m.Sessions, m.Hooks, m.AgentManagement, m.Mounted = msg.Sessions, msg.Hooks, msg.Agent, msg.Mounted
		for i, hook := range m.Hooks {
			if hook.ID == selected {
				m.Cursor = i
				break
			}
		}
		m.Cursor = max(0, min(m.Cursor, len(m.Hooks)-1))
		return m, nil
	case webhooksSavedMsg:
		if msg.Gen != m.Generation {
			return m, nil
		}
		m.Saving = false
		m.Reveal = msg.Reveal
		if msg.Err != nil {
			m.Error = msg.Err.Error()
			if msg.Reveal == nil {
				return m, nil
			}
		} else {
			m.Form = nil
			m.Notice = msg.Notice
		}
		m.Loading = true
		m.Generation++
		return m, m.loadCmd(m.Generation)
	case tea.KeyPressMsg:
		if m.Saving {
			return m, nil
		}
		if m.Reveal != nil {
			switch {
			case msg.String() == "c":
				if err := CopyText(m.Reveal.Secret); err != nil {
					m.Error = "copy failed: " + err.Error()
				} else {
					m.Error, m.Notice = "", "secret copied"
				}
			case msg.String() == "enter" || msg.String() == "esc":
				m.Reveal = nil
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
			steps, notice, err := m.Form.steps()
			if err != nil {
				m.Error = err.Error()
				return m, nil
			}
			if len(steps) == 0 {
				m.Form = nil
				m.Error, m.Notice = "", "nothing changed"
				return m, nil
			}
			return m.begin(notice, steps...)
		}
		if m.Confirm != "" {
			confirm := m.Confirm
			m.Confirm = ""
			hook := m.selected()
			if msg.String() != "enter" || hook == nil {
				return m, nil
			}
			if confirm == "delete" {
				return m.begin("deleted "+hook.Name, [2]string{"delete", hook.ID})
			}
			return m.begin("new secret for "+hook.Name, [2]string{"rotate", hook.ID})
		}
		if msg.String() == "esc" || msg.String() == "ctrl+c" {
			return m, func() tea.Msg { return WebhooksPageDoneMsg{} }
		}
		if m.Loading {
			return m, nil
		}
		if msg.String() == "r" {
			m.Error, m.Notice = "", ""
			m.Loading = true
			m.Generation++
			return m, m.loadCmd(m.Generation)
		}
		if !m.Loaded {
			return m, nil
		}
		hook := m.selected()
		switch msg.String() {
		case "up", "ctrl+p":
			m.Cursor = max(0, m.Cursor-1)
		case "down", "ctrl+n":
			m.Cursor = min(max(0, len(m.Hooks)-1), m.Cursor+1)
		case "enter":
			if hook != nil {
				m.Error, m.Notice = "", ""
				m.Form = newWebhookForm(hook, m.Sessions, m.SessionID)
			}
		case "space":
			if hook != nil {
				if hook.Enabled {
					return m.begin(hook.Name+" off · deliveries now answer 404", [2]string{"disable", hook.ID})
				}
				return m.begin(hook.Name+" on", [2]string{"enable", hook.ID})
			}
		case "n":
			m.Error, m.Notice = "", ""
			m.Form = newWebhookForm(nil, m.Sessions, m.SessionID)
		case "a":
			if m.AgentManagement {
				return m.begin("this session's agent can no longer manage its hooks", [2]string{"agent_off", ""})
			}
			return m.begin("this session's agent can now manage its own hooks", [2]string{"agent_on", ""})
		case "d":
			if hook != nil {
				m.Confirm = "delete"
			}
		case "k":
			if hook != nil {
				m.Confirm = "rotate"
			}
		case "y":
			if hook != nil {
				if err := CopyText(m.address(*hook)); err != nil {
					m.Error = "copy failed: " + err.Error()
				} else {
					m.Error, m.Notice = "", "url copied"
				}
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
	rows := []string{titleRule(width, brand("albedo")+" "+DefaultStyles.Muted.Render("/webhooks"), DefaultStyles.Faint.Render("all sessions")), ""}
	if m.Error != "" {
		rows = append(rows, DefaultStyles.Error.Render(ansi.Truncate(m.Error, width, "…")))
	}
	if m.Notice != "" {
		rows = append(rows, DefaultStyles.Faint.Render(ansi.Truncate(m.Notice, width, "…")))
	}
	if m.Loading && !m.Loaded {
		rows = append(rows, DefaultStyles.Faint.Render("loading webhooks…"))
		return strings.Join(rows, "\n")
	}
	if !m.Loaded {
		return strings.Join(append(rows, "", keyHints(hint{"r", "retry"}, hint{"esc", "back"})), "\n")
	}
	if !m.Mounted {
		rows = append(rows, DefaultStyles.Warning.Render("not listening")+DefaultStyles.Faint.Render(" · enable webhooks globally in /extensions to accept deliveries"))
	}
	agent := DefaultStyles.Faint.Render("off") + DefaultStyles.Faint.Render(" · this session's agent can't touch webhooks")
	if m.AgentManagement {
		agent = DefaultStyles.Success.Render("on ") + DefaultStyles.Faint.Render(" · this session's agent can add, rotate and delete its own hooks")
	}
	rows = append(rows, ansi.Truncate(DefaultStyles.Muted.Render("agent access ")+agent, width, "…"), "")

	if len(m.Hooks) == 0 {
		rows = append(rows, DefaultStyles.Faint.Render("no webhooks yet · each one is a signed URL that wakes a session"))
	}
	nameWidth := 4
	for _, hook := range m.Hooks {
		nameWidth = max(nameWidth, ansi.StringWidth(hook.Name))
	}
	// Hooks sit under the session they wake; the cursor line is kept in view.
	var list []string
	cursorLine := 0
	for i, hook := range m.Hooks {
		if i == 0 || hook.Session != m.Hooks[i-1].Session {
			count := 0
			for _, other := range m.Hooks {
				if other.Session == hook.Session {
					count++
				}
			}
			if i > 0 {
				list = append(list, "")
			}
			list = append(list, sectionRule(ansi.Truncate(sessionLabel(m.Sessions, hook.Session, m.SessionID), max(8, width-12), "…"), count, width))
		}
		label := DefaultStyles.Success.Render("on ")
		if !hook.Enabled {
			label = DefaultStyles.Faint.Render("off")
		}
		mark := "  "
		if i == m.Cursor {
			mark = selectBar() + " "
		}
		row := mark + label + "  " + padRight(hook.Name, nameWidth+1) + DefaultStyles.Faint.Render(hook.URL)
		if hook.Queued > 0 {
			row += DefaultStyles.Decor.Render(" · ") + DefaultStyles.Warning.Render(fmt.Sprintf("%d queued", hook.Queued))
		}
		row = ansi.Truncate(row, width, "…")
		if i == m.Cursor {
			row = selectedLine(row, width)
			cursorLine = len(list)
		}
		list = append(list, row)
	}
	listRows := max(2, m.Height-17)
	start := max(0, cursorLine-listRows+1)
	rows = append(rows, list[start:min(len(list), start+listRows)]...)

	switch {
	case m.Reveal != nil:
		rows = append(rows, "", ansi.Truncate(DefaultStyles.Bold.Render("signing secret for "+m.Reveal.Hook)+DefaultStyles.Faint.Render(" → "+sessionLabel(m.Sessions, m.Reveal.Session, m.SessionID)+" · shown once, copy it now"), width, "…"))
		rows = append(rows, "  "+DefaultStyles.Prompt.Render(m.Reveal.Secret), "")
		rows = append(rows, keyHints(hint{"c", "copy"}, hint{"enter", "done"}))
	case m.Form != nil:
		rows = append(rows, "")
		rows = append(rows, m.Form.view(width)...)
		if m.Saving {
			rows = append(rows, DefaultStyles.Faint.Render("saving…"))
		}
	case m.Confirm != "" && m.selected() != nil:
		question := "delete " + m.selected().Name + "? its URL stops working; accepted deliveries stay in the inbox"
		if m.Confirm == "rotate" {
			question = "replace the secret for " + m.selected().Name + "? the sender must be updated"
		}
		rows = append(rows, "", DefaultStyles.Warning.Render(ansi.Truncate(question, width, "…")), keyHints(hint{"enter", "confirm"}, hint{"any other key", "cancels"}))
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
			browse = append([]hint{{"↑↓", "select"}, {"space", "on/off"}, {"y", "copy url"}}, browse...)
			keys = []hint{{"n", "add hook"}, {"enter", "edit"}, {"k", "new secret"}, {"d", "delete"}, {"a", "agent access"}}
		}
		rows = append(rows, "", keyHints(browse...), keyHints(keys...))
	}
	if m.Height > 0 && len(rows) > m.Height {
		rows = append(rows[:max(1, m.Height-1)], rows[len(rows)-1])
	}
	return strings.Join(rows, "\n")
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
	Focus   int
	Inputs  map[string]*textinput.Model
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
	f := &webhookForm{Inputs: map[string]*textinput.Model{}, Sessions: sessions, Current: current, Chosen: current}
	for _, key := range hookFields {
		input := newTextInput()
		input.Prompt = ""
		input.CharLimit = 4096
		f.Inputs[key] = &input
	}
	f.Inputs[hookFieldSession].Placeholder = "type to filter"
	f.Inputs[hookFieldSecret].EchoMode = textinput.EchoPassword
	f.Inputs[hookFieldName].Placeholder = "github-deploys"
	f.Inputs[hookFieldHeader].SetValue(defaultSignatureHeader)
	f.Inputs[hookFieldPrefix].SetValue(defaultSignaturePrefix)
	f.Inputs[hookFieldSecret].Placeholder = "blank generates one"
	f.Focus = 1 // the session already defaults to this one
	if editing != nil {
		hook := *editing
		f.Editing = &hook
		f.Chosen = hook.Session
		f.Inputs[hookFieldName].SetValue(hook.Name)
		f.Inputs[hookFieldHeader].SetValue(hook.Header)
		f.Inputs[hookFieldPrefix].SetValue(hook.Prefix)
		f.Inputs[hookFieldSecret].Placeholder = "stored · blank keeps it"
		f.Focus = 2
	}
	f.focus()
	return f
}

func (f *webhookForm) current() string { return hookFields[f.Focus] }

func (f *webhookForm) focus() {
	for key, input := range f.Inputs {
		if key == f.current() {
			input.Focus()
		} else {
			input.Blur()
		}
	}
}

func (f *webhookForm) move(delta int) {
	first := 0
	if f.Editing != nil {
		first = 2
	}
	n := len(hookFields) - first
	f.Focus = first + (f.Focus-first+delta+n)%n
	f.focus()
}

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
	for i, s := range matches {
		if s.ID == f.Chosen {
			return i
		}
	}
	return -1
}

// update handles one key or paste; submit reports that the form should be saved.
func (f *webhookForm) update(msg tea.Msg) (submit bool, cmd tea.Cmd) {
	if key, ok := msg.(tea.KeyPressMsg); ok {
		switch key.String() {
		case "tab", "down":
			f.move(1)
			return false, nil
		case "shift+tab", "up":
			f.move(-1)
			return false, nil
		case "ctrl+s":
			return true, nil
		case "enter":
			if f.Focus == len(hookFields)-1 {
				return true, nil
			}
			f.move(1)
			return false, nil
		}
	}
	if f.current() == hookFieldSession {
		if key, ok := msg.(tea.KeyPressMsg); ok && (key.String() == "left" || key.String() == "right") {
			matches := f.matches()
			if len(matches) > 0 {
				step := 1
				if key.String() == "left" {
					step = -1
				}
				i := f.chosenIndex(matches)
				if i < 0 {
					i = 0
				} else {
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
	value := func(key string) string { return strings.TrimSpace(f.Inputs[key].Value()) }
	name, secret, header, prefix := value(hookFieldName), value(hookFieldSecret), value(hookFieldHeader), value(hookFieldPrefix)
	switch {
	case f.Editing == nil && f.Chosen == "":
		return nil, "", errors.New("session: choose the session this hook wakes")
	case f.Editing == nil && !hookName.MatchString(name):
		return nil, "", errors.New("name: use 1–64 letters, digits, _ or -")
	case secret != "" && (len(secret) < 16 || len(secret) > 4096):
		return nil, "", errors.New("secret: use 16–4096 bytes, or leave it blank")
	case strings.ContainsAny(secret, " \t"):
		return nil, "", errors.New("secret: spaces are not allowed")
	case !hookHeader.MatchString(header):
		return nil, "", errors.New("header: use 1–64 letters, digits or -")
	case len(prefix) > 32 || strings.ContainsAny(prefix, " \t"):
		return nil, "", errors.New("prefix: at most 32 characters, no spaces")
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
	hook := f.Editing
	var steps [][2]string
	if !strings.EqualFold(header, hook.Header) || prefix != hook.Prefix {
		steps = append(steps, [2]string{"signature", hook.ID + " " + header + " " + prefix})
	}
	if secret != "" {
		steps = append(steps, [2]string{"rotate_with_secret", hook.ID + " " + secret})
	}
	return steps, "saved " + hook.Name, nil
}

func (f *webhookForm) view(width int) []string {
	title := "add webhook"
	if f.Editing != nil {
		title = "edit " + f.Editing.Name
	}
	fitInputs(f.Inputs, width-14)
	rows := []string{DefaultStyles.Bold.Render(title)}
	indent := strings.Repeat(" ", 13)
	for i, key := range hookFields {
		mark := "  "
		if i == f.Focus {
			mark = promptLead()
		}
		value := f.Inputs[key].View()
		switch {
		case key == hookFieldSession && f.Editing != nil:
			value = DefaultStyles.Faint.Render(sessionLabel(f.Sessions, f.Chosen, f.Current))
		case key == hookFieldSession && i != f.Focus:
			value = sessionLabel(f.Sessions, f.Chosen, f.Current)
		case key == hookFieldName && f.Editing != nil:
			value = DefaultStyles.Faint.Render(f.Editing.Name)
		}
		rows = append(rows, ansi.Truncate(mark+padRight(key, 11)+value, width, "…"))
		if key == hookFieldSession && i == f.Focus {
			rows = append(rows, f.pickerRows(indent, width)...)
		}
	}
	var note string
	keys := []hint{{"tab/↑↓", "move"}, {"enter", "next"}, {"ctrl+s", "save"}, {"esc", "cancel"}}
	switch f.current() {
	case hookFieldSession:
		note = "which session deliveries wake"
		keys = append([]hint{{"←→", "choose"}}, keys...)
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
	line := DefaultStyles.Faint.Render(note) + DefaultStyles.Decor.Render(" · ") + keyHints(keys...)
	return append(rows, "", ansi.Truncate(line, width, "…"))
}

// pickerRows lists the matching sessions around the chosen one.
func (f *webhookForm) pickerRows(indent string, width int) []string {
	matches := f.matches()
	if len(matches) == 0 {
		return []string{indent + DefaultStyles.Faint.Render("no session matches")}
	}
	chosen := max(0, f.chosenIndex(matches))
	start := max(0, min(chosen-sessionChoices/2, len(matches)-sessionChoices))
	var rows []string
	for i := start; i < min(len(matches), start+sessionChoices); i++ {
		label := sessionLabel(f.Sessions, matches[i].ID, f.Current)
		if i == chosen {
			rows = append(rows, indent+selectedLine(ansi.Truncate(selectBar()+" "+label, width-len(indent), "…"), width-len(indent)))
		} else {
			rows = append(rows, indent+DefaultStyles.Faint.Render(ansi.Truncate("  "+label, width-len(indent), "…")))
		}
	}
	if more := len(matches) - sessionChoices; more > 0 {
		rows = append(rows, indent+DefaultStyles.Faint.Render(fmt.Sprintf("  %d more · type to filter", more)))
	}
	return rows
}
