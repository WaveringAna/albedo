package tui

import (
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/cursor"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
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
	Input   string   `json:"input"` // "none" | "text" | "choice" | "value"
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
	ti := textinput.New()
	ti.Cursor.SetMode(cursor.CursorStatic)
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
	m.TextInput.Width = max(10, width-20)
}

func (m PageViewModel) Init() tea.Cmd {
	return m.loadPageCmd(m.Generation)
}

func parsePageDocument(result any) (*PageDocument, error) {
	response, ok := result.(map[string]any)
	if !ok {
		return nil, errors.New("command did not answer a page")
	}
	page, ok := response["page"].(map[string]any)
	if !ok {
		return nil, errors.New("command did not answer a page")
	}
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
			if tone != "plain" && tone != "active" && tone != "warning" && tone != "muted" {
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
			case "text":
				action.Input = "text"
				action.Prompt = label
				if prompt, ok := obj["prompt"].(string); ok {
					action.Prompt = prompt
				}
				action.Prefill = obj["prefill"] == true
			case "choice":
				choices, ok := obj["options"].([]any)
				if !ok || len(choices) == 0 {
					continue
				}
				action.Input = "choice"
				for _, raw := range choices {
					value, ok := raw.(string)
					if !ok {
						action.Options = nil
						break
					}
					action.Options = append(action.Options, value)
				}
				if len(action.Options) != len(choices) {
					continue
				}
			case "value":
				value, ok := obj["value"].(string)
				if !ok {
					continue
				}
				action.Input = "value"
				action.Value = value
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

		var targetObj any = res
		if r, ok := res["result"]; ok && r != nil {
			targetObj = r
		}
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

		val := entered
		if act.Input == "value" {
			val = act.Value
		}

		var detailsParts []string
		if act.Row && row != nil {
			detailsParts = append(detailsParts, row.ID)
		}
		if val != "" {
			detailsParts = append(detailsParts, val)
		}
		details := strings.Join(detailsParts, " ")

		path := fmt.Sprintf("/sessions/%s/commands", m.SessionID)
		body := map[string]any{
			"name": m.Command,
			"args": map[string]string{
				"action":  act.Run,
				"details": details,
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
	for i := range m.Doc.Rows {
		if m.Doc.Rows[i].ID == m.SelectedID {
			return &m.Doc.Rows[i]
		}
	}
	return &m.Doc.Rows[0]
}

func (m PageViewModel) currentIndex() int {
	if m.Doc == nil || len(m.Doc.Rows) == 0 {
		return 0
	}
	for i := range m.Doc.Rows {
		if m.Doc.Rows[i].ID == m.SelectedID {
			return i
		}
	}
	return 0
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
		if m.currentRow() != nil {
			m.SelectedID = m.currentRow().ID
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

		// Notice from result or action label
		notice := fmt.Sprintf("%s done", msg.Action.Label)
		if msg.Result != nil {
			if r, ok := msg.Result["result"].(map[string]any); ok {
				if msgStr, ok := r["message"].(string); ok && msgStr != "" {
					notice = msgStr
				}
			} else if msgStr, ok := msg.Result["message"].(string); ok && msgStr != "" {
				notice = msgStr
			}
		}
		m.Notice = notice
		m.Error = ""

		// Reload page and notify changed
		m.Busy = true
		m.Generation++
		return m, tea.Batch(
			func() tea.Msg { return PageViewChangedMsg{} },
			m.loadPageCmd(m.Generation),
		)

	case tea.KeyMsg:
		if msg.Type == tea.KeyCtrlC || msg.Type == tea.KeyEsc {
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
			if msg.Type == tea.KeyEnter && m.CurrentAction != nil {
				act := *m.CurrentAction
				m.CurrentAction = nil
				m.Mode = modeBrowse
				// If action still needs text or choice, collect it
				switch act.Input {
				case "text":
					m.Mode = modeText
					m.CurrentAction = &act
					m.TextInput.Reset()
					if act.Prefill && m.currentRow() != nil {
						m.TextInput.SetValue(m.currentRow().Text)
					}
					m.TextInput.Focus()
					return m, textinput.Blink
				case "choice":
					m.Mode = modeChoice
					m.CurrentAction = &act
					m.ChoiceIndex = 0
					if row := m.currentRow(); row != nil {
						for i, opt := range act.Options {
							if opt == row.Badge {
								m.ChoiceIndex = i
								break
							}
						}
					}
					return m, nil
				default:
					m.Busy = true
					m.Error = ""
					m.Notice = ""
					m.Generation++
					return m, m.executeActionCmd(act, m.currentRow(), "", m.Generation)
				}
			}
			return m, nil

		case modeChoice:
			if m.CurrentAction != nil && len(m.CurrentAction.Options) > 0 {
				numOpts := len(m.CurrentAction.Options)
				switch msg.Type {
				case tea.KeyLeft, tea.KeyUp:
					m.ChoiceIndex = (m.ChoiceIndex - 1 + numOpts) % numOpts
				case tea.KeyRight, tea.KeyDown:
					m.ChoiceIndex = (m.ChoiceIndex + 1) % numOpts
				case tea.KeyEnter:
					act := *m.CurrentAction
					chosenOpt := act.Options[m.ChoiceIndex]
					m.CurrentAction = nil
					m.Mode = modeBrowse
					m.Busy = true
					m.Error = ""
					m.Notice = ""
					m.Generation++
					return m, m.executeActionCmd(act, m.currentRow(), chosenOpt, m.Generation)
				}
			}
			return m, nil

		case modeText:
			switch msg.Type {
			case tea.KeyEnter:
				val := strings.TrimSpace(m.TextInput.Value())
				if val != "" && m.CurrentAction != nil {
					act := *m.CurrentAction
					m.CurrentAction = nil
					m.Mode = modeBrowse
					m.Busy = true
					m.Error = ""
					m.Notice = ""
					m.Generation++
					return m, m.executeActionCmd(act, m.currentRow(), val, m.Generation)
				}
				return m, nil
			}
			var cmd tea.Cmd
			m.TextInput, cmd = m.TextInput.Update(msg)
			return m, cmd

		case modeBrowse:
			idx := m.currentIndex()
			switch msg.Type {
			case tea.KeyUp, tea.KeyCtrlP:
				if idx > 0 {
					m.SelectedID = m.Doc.Rows[idx-1].ID
				}
			case tea.KeyDown, tea.KeyCtrlN:
				if idx < len(m.Doc.Rows)-1 {
					m.SelectedID = m.Doc.Rows[idx+1].ID
				}
			default:
				// Match action key
				keyStr := msg.String()
				for _, act := range m.Doc.Actions {
					if act.Key == keyStr {
						actionCopy := act
						if actionCopy.Row && m.currentRow() == nil {
							continue
						}
						m.Notice = ""
						m.Error = ""

						if actionCopy.Confirm {
							m.Mode = modeConfirm
							m.CurrentAction = &actionCopy
							return m, nil
						}

						switch actionCopy.Input {
						case "text":
							m.Mode = modeText
							m.CurrentAction = &actionCopy
							m.TextInput.Reset()
							if actionCopy.Prefill && m.currentRow() != nil {
								m.TextInput.SetValue(m.currentRow().Text)
							}
							m.TextInput.Focus()
							return m, textinput.Blink
						case "choice":
							m.Mode = modeChoice
							m.CurrentAction = &actionCopy
							m.ChoiceIndex = 0
							if m.currentRow() != nil {
								for optIdx, opt := range actionCopy.Options {
									if opt == m.currentRow().Badge {
										m.ChoiceIndex = optIdx
										break
									}
								}
							}
							return m, nil
						default:
							m.Busy = true
							m.Generation++
							return m, m.executeActionCmd(actionCopy, m.currentRow(), "", m.Generation)
						}
					}
				}
			}
		}
	}
	return m, nil
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
		if m.Error != "" {
			faint("r retry · esc return to chat")
		} else {
			faint("loading " + m.Command + "…")
		}
		return strings.TrimSuffix(b.String(), "\n")
	}
	row := m.currentRow()
	if len(m.Doc.Rows) == 0 {
		faint(m.Doc.Empty)
	} else {
		rows := make([]string, len(m.Doc.Rows))
		for i, item := range m.Doc.Rows {
			var style lipgloss.Style
			switch item.Tone {
			case ToneActive:
				style = DefaultStyles.Success
			case ToneWarning:
				style = DefaultStyles.Warning
			case ToneMuted:
				style = m.Styles.Faint
			default:
				style = lipgloss.NewStyle()
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
		if row.ID == row.Text {
			target = " " + row.Text
		} else {
			target = fmt.Sprintf(" #%s %s", row.ID, row.Text)
		}
	}
	if m.CurrentAction != nil {
		act := m.CurrentAction
		actionTarget := ""
		if act.Row {
			actionTarget = target
		}
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
			prompt := act.Prompt
			if prompt == "" {
				prompt = act.Label
			}
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
