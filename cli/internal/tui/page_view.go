package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

type PageTone string

const (
	TonePlain   PageTone = "plain"
	ToneActive  PageTone = "active"
	ToneWarning PageTone = "warning"
	ToneMuted   PageTone = "muted"
)

type PageRow struct {
	ID    string   `json:"id"`
	Text  string   `json:"text"`
	Badge string   `json:"badge"`
	Tone  PageTone `json:"tone"`
}

type PageAction struct {
	Key     string   `json:"key"`
	Label   string   `json:"label"`
	Run     string   `json:"run"`
	Row     bool     `json:"row"`
	Confirm bool     `json:"confirm"`
	Input   string   `json:"input"` // "none" | "text" | "secret" | "choice" | "value"
	Prompt  string   `json:"prompt,omitempty"`
	Prefill bool     `json:"prefill,omitempty"`
	Options []string `json:"options,omitempty"`
	Value   string   `json:"value,omitempty"`
}

type PageGlance struct {
	Title string    `json:"title"`
	Rows  []PageRow `json:"rows"`
}

type PageDocument struct {
	Title   string       `json:"title"`
	Summary string       `json:"summary"`
	Empty   string       `json:"empty"`
	Rows    []PageRow    `json:"rows"`
	Actions []PageAction `json:"actions"`
	Glance  *PageGlance  `json:"glance,omitempty"`
}

type PageCancelMsg struct{}
type PageViewChangedMsg struct{}

type pageLoadedMsg struct {
	Doc *PageDocument
	Err error
	Gen int
}

type pageActionExecutedMsg struct {
	Result map[string]any
	Action PageAction
	Err    error
	Gen    int
}

type pageModeKind int

const (
	modeBrowse pageModeKind = iota
	modeText
	modeChoice
	modeConfirm
)

type PageViewModel struct {
	Conn          *daemon.Connection
	SessionID     string
	Command       string
	Doc           *PageDocument
	SelectedID    string
	Mode          pageModeKind
	CurrentAction *PageAction
	ChoiceIndex   int
	TextInput     textinput.Model
	Busy          bool
	Notice        string
	Error         string
	Generation    int
	Width         int
	Height        int
	Styles        Styles
}

func NewPageViewModel(conn *daemon.Connection, sessionID, command string) PageViewModel {
	ti := newTextInput()
	ti.Prompt = ""
	return PageViewModel{
		Conn:      conn,
		SessionID: sessionID,
		Command:   command,
		TextInput: ti,
		Busy:      true,
		Styles:    DefaultStyles,
	}
}

func (m *PageViewModel) SetSize(width, height int) {
	m.Width = width
	m.Height = height
	m.TextInput.SetWidth(max(10, width-20))
}

func (m PageViewModel) Init() tea.Cmd {
	return m.loadPageCmd(m.Generation)
}

func parsePageDocument(result any) (*PageDocument, error) {
	response, _ := result.(map[string]any)
	page, _ := response["page"].(map[string]any)
	title, ok := page["title"].(string)
	if !ok {
		return nil, errors.New("command did not answer a page")
	}
	doc := &PageDocument{Title: title, Empty: "nothing here yet"}
	if summary, ok := page["summary"].(string); ok {
		doc.Summary = summary
	}
	if empty, ok := page["empty"].(string); ok {
		doc.Empty = empty
	}
	parseRows := func(raw any) []PageRow {
		result := []PageRow{}
		entries, _ := raw.([]any)
		for _, entry := range entries {
			obj, ok := entry.(map[string]any)
			if !ok {
				continue
			}
			id, idOK := obj["id"].(string)
			text, textOK := obj["text"].(string)
			badge, badgeOK := obj["badge"].(string)
			if !idOK || !textOK || !badgeOK {
				continue
			}
			tone, _ := obj["tone"].(string)
			switch tone {
			case "active", "warning", "muted":
			default:
				tone = "plain"
			}
			result = append(result, PageRow{ID: id, Text: text, Badge: badge, Tone: PageTone(tone)})
		}
		return result
	}
	doc.Rows = parseRows(page["rows"])
	if raw, ok := page["actions"].([]any); ok {
		for _, entry := range raw {
			obj, ok := entry.(map[string]any)
			if !ok {
				continue
			}
			key, keyOK := obj["key"].(string)
			label, labelOK := obj["label"].(string)
			run, runOK := obj["run"].(string)
			if !keyOK || len([]rune(key)) != 1 || !labelOK || !runOK {
				continue
			}
			action := PageAction{Key: key, Label: label, Run: run, Row: obj["row"] == true, Confirm: obj["confirm"] == true, Input: "none"}
			kind, _ := obj["input"].(string)
			switch kind {
			case "text", "secret":
				action.Input, action.Prompt = kind, label
				if prompt, ok := obj["prompt"].(string); ok {
					action.Prompt = prompt
				}
				action.Prefill = obj["prefill"] == true
			case "choice":
				choices, _ := obj["options"].([]any)
				if len(choices) == 0 {
					continue
				}
				var opts []string
				for _, raw := range choices {
					value, ok := raw.(string)
					if !ok {
						break
					}
					opts = append(opts, value)
				}
				if len(opts) != len(choices) {
					continue
				}
				action.Input, action.Options = "choice", opts
			case "value":
				value, ok := obj["value"].(string)
				if !ok {
					continue
				}
				action.Input, action.Value = "value", value
			}
			doc.Actions = append(doc.Actions, action)
		}
	}
	if glance, ok := page["glance"].(map[string]any); ok {
		if title, ok := glance["title"].(string); ok {
			doc.Glance = &PageGlance{Title: title, Rows: parseRows(glance["rows"])}
		}
	}
	return doc, nil
}

func (m PageViewModel) loadPageCmd(gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return pageLoadedMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}
		path := fmt.Sprintf("/sessions/%s/commands", m.SessionID)
		body := map[string]any{"name": m.Command, "args": map[string]string{}}
		res, err := daemon.Request[map[string]any](context.Background(), m.Conn, path, body)
		if err != nil {
			return pageLoadedMsg{Err: err, Gen: gen}
		}

		targetObj := pick(res["result"] != nil, res["result"], any(res))
		doc, err := parsePageDocument(targetObj)
		if err != nil {
			err = fmt.Errorf("%s did not answer a page", m.Command)
		}
		return pageLoadedMsg{Doc: doc, Err: err, Gen: gen}
	}
}

func (m PageViewModel) executeActionCmd(act PageAction, row *PageRow, entered string, gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return pageActionExecutedMsg{Action: act, Err: errors.New("daemon connection unavailable"), Gen: gen}
		}

		val := pick(act.Input == "value", act.Value, entered)
		var details []string
		if act.Row && row != nil {
			details = append(details, row.ID)
		}
		if val != "" {
			details = append(details, val)
		}

		path := fmt.Sprintf("/sessions/%s/commands", m.SessionID)
		body := map[string]any{
			"name": m.Command,
			"args": map[string]string{
				"action":  act.Run,
				"details": strings.Join(details, " "),
			},
		}

		res, err := daemon.Request[map[string]any](context.Background(), m.Conn, path, body)
		return pageActionExecutedMsg{Result: res, Action: act, Err: err, Gen: gen}
	}
}

func (m PageViewModel) currentRow() *PageRow {
	if m.Doc == nil || len(m.Doc.Rows) == 0 {
		return nil
	}
	return &m.Doc.Rows[m.currentIndex()]
}

func (m PageViewModel) currentIndex() int {
	if m.Doc != nil {
		if i := slices.IndexFunc(m.Doc.Rows, func(r PageRow) bool { return r.ID == m.SelectedID }); i >= 0 {
			return i
		}
	}
	return 0
}

// runAction marks the page busy and asks the daemon to run act.
func (m *PageViewModel) runAction(act PageAction, entered string) tea.Cmd {
	m.Mode, m.CurrentAction = modeBrowse, nil
	m.Busy, m.Error, m.Notice = true, "", ""
	m.Generation++
	return m.executeActionCmd(act, m.currentRow(), entered, m.Generation)
}

// beginAction opens the interaction act needs: Update asks for a
// confirmation first, then come text entry or a choice, or the action runs
// at once. fresh clears a stale notice and error, as acting from the row
// list does.
func (m *PageViewModel) beginAction(act PageAction, fresh bool) tea.Cmd {
	if fresh {
		m.Notice, m.Error = "", ""
	}
	m.CurrentAction = &act
	switch act.Input {
	case "text", "secret":
		m.Mode = modeText
		m.TextInput.Reset()
		m.TextInput.EchoMode = pick(act.Input == "secret", textinput.EchoPassword, textinput.EchoNormal)
		if act.Prefill && m.currentRow() != nil {
			m.TextInput.SetValue(m.currentRow().Text)
		}
		m.TextInput.Focus()
		return textinput.Blink
	case "choice":
		m.Mode = modeChoice
		m.ChoiceIndex = 0
		if row := m.currentRow(); row != nil {
			if i := slices.Index(act.Options, row.Badge); i >= 0 {
				m.ChoiceIndex = i
			}
		}
		return nil
	}
	return m.runAction(act, "")
}

func (m PageViewModel) Update(msg tea.Msg) (PageViewModel, tea.Cmd) {
	switch msg := msg.(type) {
	case pageLoadedMsg:
		if msg.Gen != m.Generation {
			return m, nil
		}
		m.Busy = false
		if msg.Err != nil {
			m.Error = msg.Err.Error()
			return m, nil
		}
		m.Doc = msg.Doc
		m.Error = ""
		if row := m.currentRow(); row != nil {
			m.SelectedID = row.ID
		}
		return m, nil

	case pageActionExecutedMsg:
		if msg.Gen != m.Generation {
			return m, nil
		}
		m.Busy = false
		if msg.Err != nil {
			m.Error = msg.Err.Error()
			return m, nil
		}
		m.Notice = pageNotice(msg)
		m.Error = ""
		m.Busy = true
		m.Generation++
		return m, tea.Batch(
			func() tea.Msg { return PageViewChangedMsg{} },
			m.loadPageCmd(m.Generation),
		)

	case tea.KeyPressMsg:
		if msg.String() == "ctrl+c" || msg.String() == "esc" {
			if m.Mode == modeBrowse {
				return m, func() tea.Msg { return PageCancelMsg{} }
			}
			m.Mode = modeBrowse
			m.CurrentAction = nil
			return m, nil
		}
		if m.Busy {
			return m, nil
		}
		if m.Doc == nil {
			if strings.ToLower(msg.String()) == "r" {
				m.Busy = true
				m.Error = ""
				m.Generation++
				return m, m.loadPageCmd(m.Generation)
			}
			return m, nil
		}
		switch m.Mode {
		case modeConfirm:
			if msg.String() == "enter" && m.CurrentAction != nil {
				act := *m.CurrentAction
				m.CurrentAction = nil
				m.Mode = modeBrowse
				return m, m.beginAction(act, false)
			}
		case modeChoice:
			if m.CurrentAction != nil && len(m.CurrentAction.Options) > 0 {
				opts := m.CurrentAction.Options
				switch msg.String() {
				case "left", "up":
					m.ChoiceIndex = (m.ChoiceIndex - 1 + len(opts)) % len(opts)
				case "right", "down":
					m.ChoiceIndex = (m.ChoiceIndex + 1) % len(opts)
				case "enter":
					return m, m.runAction(*m.CurrentAction, opts[m.ChoiceIndex])
				}
			}
		case modeText:
			if msg.String() != "enter" {
				var cmd tea.Cmd
				m.TextInput, cmd = m.TextInput.Update(msg)
				return m, cmd
			}
			if val := strings.TrimSpace(m.TextInput.Value()); val != "" && m.CurrentAction != nil {
				act := *m.CurrentAction
				m.TextInput.Reset()
				return m, m.runAction(act, val)
			}
		case modeBrowse:
			idx := m.currentIndex()
			switch msg.String() {
			case "up", "ctrl+p":
				if idx > 0 {
					m.SelectedID = m.Doc.Rows[idx-1].ID
				}
			case "down", "ctrl+n":
				if idx < len(m.Doc.Rows)-1 {
					m.SelectedID = m.Doc.Rows[idx+1].ID
				}
			default:
				for _, act := range m.Doc.Actions {
					if act.Key != msg.String() {
						continue
					}
					if act.Row && m.currentRow() == nil {
						continue
					}
					if act.Confirm {
						m.Notice, m.Error = "", ""
						m.Mode = modeConfirm
						m.CurrentAction = &act
						return m, nil
					}
					return m, m.beginAction(act, true)
				}
			}
		}
	}
	return m, nil
}

// pageNotice picks the wording for a finished action: the daemon's message
// when it sent one, else the action's label.
func pageNotice(msg pageActionExecutedMsg) string {
	notice := fmt.Sprintf("%s done", msg.Action.Label)
	if msg.Result == nil {
		return notice
	}
	r, _ := msg.Result["result"].(map[string]any)
	if r == nil {
		r = msg.Result
	}
	if s, ok := r["message"].(string); ok && s != "" {
		return s
	}
	return notice
}

func (m PageViewModel) View() string {
	var b strings.Builder
	line := func(text string) { b.WriteString(text); b.WriteByte('\n') }
	faint := func(text string) { line(m.Styles.Faint.Render(text)) }
	summary := ""
	if m.Doc != nil {
		summary = m.Styles.Faint.Render(m.Doc.Summary)
	}
	line(titleRule(m.Width, brand("albedo")+" "+m.Styles.Muted.Render(m.Command), summary))
	if m.Error != "" {
		line(DefaultStyles.Error.Render(m.Error))
	}
	if m.Notice != "" && m.Error == "" {
		line(m.Styles.Faint.Render(m.Notice))
	}
	if m.Doc == nil {
		faint(pick(m.Error != "", "r retry · esc return to chat", "loading "+m.Command+"…"))
		return strings.TrimSuffix(b.String(), "\n")
	}
	row := m.currentRow()
	if len(m.Doc.Rows) == 0 {
		faint(m.Doc.Empty)
	} else {
		rows := make([]string, len(m.Doc.Rows))
		for i, item := range m.Doc.Rows {
			style := lipgloss.NewStyle()
			switch item.Tone {
			case ToneActive:
				style = DefaultStyles.Success
			case ToneWarning:
				style = DefaultStyles.Warning
			case ToneMuted:
				style = m.Styles.Faint
			}
			rows[i] = style.Render(fmt.Sprintf("%-9s", item.Badge)) + " " + item.Text
			if item.ID != item.Text {
				rows[i] += DefaultStyles.Faint.Render("  #" + item.ID)
			}
		}
		line(selectableRows(rows, m.currentIndex(), m.Height, m.Height, m.Width, m.Styles))
	}
	target := ""
	if row != nil {
		target = " " + row.Text
		if row.ID != row.Text {
			target = " #" + row.ID + " " + row.Text
		}
	}
	if m.CurrentAction != nil {
		act := m.CurrentAction
		actionTarget := pick(act.Row, target, "")
		switch m.Mode {
		case modeConfirm:
			line(DefaultStyles.Warning.Render(act.Label + actionTarget + "? enter confirm · esc cancel"))
		case modeChoice:
			var choice strings.Builder
			choice.WriteString(m.Styles.Prompt.Render(act.Label+target) + " " + promptLead())
			for i, opt := range act.Options {
				label := " " + opt + " "
				if i == m.ChoiceIndex {
					label = selectedLine(label, 0)
				}
				choice.WriteString(label)
			}
			line(choice.String())
		case modeText:
			prompt := cmp.Or(act.Prompt, act.Label)
			b.WriteString(m.Styles.Prompt.Render(act.Label+actionTarget+" · "+prompt) + " " + promptLead())
			line(m.TextInput.View())
		}
	}
	var hints []hint
	switch {
	case m.Busy:
		hints = []hint{{"working…", ""}}
	case m.Mode == modeBrowse:
		if len(m.Doc.Rows) > 1 {
			hints = append(hints, hint{"↑↓", "select"})
		}
		for _, act := range m.Doc.Actions {
			if !act.Row || row != nil {
				hints = append(hints, hint{act.Key, act.Label})
			}
		}
		hints = append(hints, hint{"esc", "return to chat"})
	case m.Mode == modeText:
		hints = []hint{{"enter", "save"}, {"esc", "cancel"}}
	case m.Mode == modeChoice:
		hints = []hint{{"←→", "choose"}, {"enter", "apply"}, {"esc", "cancel"}}
	}
	footer := keyHints(hints...)
	if m.Width > 0 {
		footer = ansi.Truncate(footer, m.Width, "…")
	}
	line(footer)
	return strings.TrimSuffix(b.String(), "\n")
}
