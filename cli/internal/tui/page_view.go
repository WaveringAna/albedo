package tui

import (
	"albedo/cli/internal/daemon"
	"context"
	"encoding/json"
	"errors"
	"maps"
	"slices"
	"strings"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
)

type PageTone = daemon.PageTone

const (
	TonePlain   = daemon.TonePlain
	ToneActive  = daemon.ToneActive
	ToneWarning = daemon.ToneWarning
	ToneMuted   = daemon.ToneMuted
)

type PageRow = daemon.PageRow
type PageAction = daemon.PageAction
type PageGlance = daemon.PageGlance
type PageDocument = daemon.PageDocument

type PageCancelMsg struct{}
type PageViewChangedMsg struct{}

type pageLoadedMsg struct {
	Doc *PageDocument
	Err error
	Gen int
}

type pageShortcutPreparedMsg struct {
	Prepared *daemon.PreparedPageAction
	Err      error
	Gen      int
}

type pageActionExecutedMsg struct {
	Prepared *PageDocument
	Err      error
	Message  string
	Action   PageAction
	Gen      int
}

type pageModeKind int

const (
	modeBrowse pageModeKind = iota
	modeText
	modeChoice
	modeConfirm
	modeActions
)

type PageViewModel struct {
	Styles        Styles
	Conn          *daemon.Connection
	Doc           *PageDocument
	CurrentAction *PageAction
	SessionID     string
	Command       string
	SelectedID    string
	TextInput     textinput.Model
	page
	Mode                    pageModeKind
	ChoiceIndex             int
	FieldIndex, ActionIndex int
	FormValues              map[string]json.RawMessage
	Busy                    bool
}

func NewPageViewModel(conn *daemon.Connection, sessionID, command string) PageViewModel {
	return PageViewModel{
		Conn:      conn,
		SessionID: sessionID,
		Command:   command,
		TextInput: newField(),
		page:      page{Generation: nextPageGeneration()},
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

func (m PageViewModel) loadPageCmd(gen int) tea.Cmd {
	previous := m.Doc
	return func() tea.Msg {
		if m.Conn == nil {
			return pageLoadedMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}
		doc, err := daemon.RefreshPage(context.Background(), m.Conn, m.SessionID, m.Command, previous)
		if err != nil {
			return pageLoadedMsg{Err: err, Gen: gen}
		}

		return pageLoadedMsg{Doc: doc, Gen: gen}
	}
}

func (m PageViewModel) executeActionCmd(act PageAction, row *PageRow, gen int) tea.Cmd {
	form := maps.Clone(m.FormValues)
	var session *daemon.Session
	if m.Doc != nil {
		session = m.Doc.Session
	}
	return func() tea.Msg {
		if m.Conn == nil {
			return pageActionExecutedMsg{Action: act, Err: errors.New("daemon connection unavailable"), Gen: gen}
		}

		if act.Operation.OperationID == "mergeLinkGroups" {
			if raw, ok := form["other_workspace"]; ok {
				var target string
				if json.Unmarshal(raw, &target) == nil && session != nil {
					if _, hasValidator := form["other_etag"]; !hasValidator {
						prepared, err := daemon.PrepareLinkMerge(context.Background(), m.Conn, *session, target)
						return pageActionExecutedMsg{Action: act, Gen: gen, Prepared: prepared, Err: err}
					}
				}
			}
		}
		res, err := daemon.ExecutePageAction(context.Background(), m.Conn, daemon.PageActionRequest{Action: act, Row: row, Form: form, Session: session})
		return pageActionExecutedMsg{Message: res.Message, Prepared: res.Page, Action: act, Err: err, Gen: gen}
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
	if len(act.Fields) > 0 && m.FieldIndex < len(act.Fields) {
		field := act.Fields[m.FieldIndex]
		if entered != "" || field.Required || field.Default != nil {
			value, err := daemon.ParseActionField(field, entered)
			if err != nil {
				m.Error = err.Error()
				return nil
			}
			if m.FormValues == nil {
				m.FormValues = map[string]json.RawMessage{}
			}
			if value != nil {
				m.FormValues[field.Name] = value
			}
		}
		m.TextInput.Reset()
		m.FieldIndex++
		if m.FieldIndex < len(act.Fields) {
			return m.promptField(act)
		}
	}
	m.Mode, m.CurrentAction = modeBrowse, nil
	m.Busy, m.Error, m.Notice = true, "", ""
	m.Generation = nextPageGeneration()
	cmd := m.executeActionCmd(act, m.currentRow(), m.Generation)
	m.TextInput.Reset()
	m.FormValues = nil
	m.FieldIndex = 0
	return cmd
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
	if len(act.Fields) > 0 {
		m.FieldIndex = 0
		m.FormValues = map[string]json.RawMessage{}
		return m.promptField(act)
	}
	return m.runAction(act, "")
}

func (m PageViewModel) Update(msg tea.Msg) (PageViewModel, tea.Cmd) {
	switch msg := msg.(type) {
	case pageLoadedMsg:
		if !m.settle(msg.Gen, msg.Err, &m.Busy) {
			return m, nil
		}
		m.Doc = msg.Doc
		m.Error = ""
		if row := m.currentRow(); row != nil {
			m.SelectedID = row.ID
		}
		return m, nil

	case pageShortcutPreparedMsg:
		if !m.settle(msg.Gen, msg.Err, &m.Busy) {
			return m, nil
		}
		prepared := msg.Prepared
		m.Doc = prepared.Page
		m.Error = ""
		if prepared.Request.Row != nil {
			m.SelectedID = prepared.Request.Row.ID
		}
		act := prepared.Request.Action
		if act.Confirm {
			m.CurrentAction = &act
			m.Mode = modeConfirm
			return m, nil
		}
		m.FormValues = prepared.Request.Form
		m.Generation = nextPageGeneration()
		m.Busy = true
		cmd := m.executeActionCmd(act, prepared.Request.Row, m.Generation)
		m.FormValues = nil
		return m, cmd

	case pageActionExecutedMsg:
		if !m.settle(msg.Gen, msg.Err, &m.Busy) {
			return m, nil
		}
		if msg.Prepared != nil {
			m.Doc = msg.Prepared
			m.Mode = modeBrowse
			m.Busy = false
			m.CurrentAction = nil
			m.SelectedID = ""
			return m, nil
		}
		m.Notice = pageNotice(msg)
		m.Error = ""
		m.Busy = true
		m.Generation = nextPageGeneration()
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
			m.FormValues = nil
			m.TextInput.Reset()
			m.FieldIndex = 0
			return m, nil
		}
		if m.Busy {
			return m, nil
		}
		if m.Doc == nil {
			if strings.ToLower(msg.String()) == "r" {
				m.Busy = true
				m.Error = ""
				m.Generation = nextPageGeneration()
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
			if opts := m.fieldChoices(); len(opts) > 0 {
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
			if val := m.TextInput.Value(); m.CurrentAction != nil {
				act := *m.CurrentAction
				m.TextInput.Reset()
				return m, m.runAction(act, val)
			}
		case modeActions:
			switch msg.String() {
			case "up", "ctrl+p":
				m.ActionIndex = max(0, m.ActionIndex-1)
			case "down", "ctrl+n":
				m.ActionIndex = min(len(m.Doc.Actions)-1, m.ActionIndex+1)
			case "enter":
				if len(m.Doc.Actions) > 0 {
					act := m.Doc.Actions[m.ActionIndex]
					if act.Row && m.currentRow() == nil {
						m.Error = "Select a row for this action."
						break
					}
					if act.Confirm {
						m.CurrentAction = &act
						m.Mode = modeConfirm
					} else {
						return m, m.beginAction(act, true)
					}
				}
			}
			return m, nil
		case modeBrowse:
			idx := m.currentIndex()
			switch msg.String() {
			case "ctrl+a":
				m.Mode = modeActions
				m.ActionIndex = 0
				return m, nil
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
	if m.Mode == modeText && m.TextInput.Focused() {
		var cmd tea.Cmd
		m.TextInput, cmd = m.TextInput.Update(msg)
		return m, cmd
	}
	return m, nil
}

func (m *PageViewModel) promptField(act PageAction) tea.Cmd {
	field := act.Fields[m.FieldIndex]
	var session *daemon.Session
	if m.Doc != nil {
		session = m.Doc.Session
	}
	resolved, err := daemon.ResolveFormField(field, m.currentRow(), session)
	if err != nil {
		m.Error = err.Error()
		m.Mode = modeBrowse
		return nil
	}
	field = resolved
	act.Fields = slices.Clone(act.Fields)
	act.Fields[m.FieldIndex] = field
	m.CurrentAction = &act
	if field.Type == "hidden" {
		return m.runAction(act, "")
	}
	if field.Type == "choice" || field.Type == "boolean" {
		m.Mode = modeChoice
		m.ChoiceIndex = daemon.FormChoiceDefault(field)
		return nil
	}
	m.Mode = modeText
	initial := ""
	if field.Default != nil {
		if json.Unmarshal(field.Default, &initial) != nil && string(field.Default) != "null" {
			initial = string(field.Default)
		}
	}
	return ask(&m.TextInput, initial, field.Type == "secret")
}

func (m PageViewModel) currentField() daemon.FormField {
	if m.CurrentAction != nil && m.FieldIndex < len(m.CurrentAction.Fields) {
		return m.CurrentAction.Fields[m.FieldIndex]
	}
	return daemon.FormField{}
}

func (m PageViewModel) fieldChoices() []string {
	field := m.currentField()
	if field.Type == "boolean" {
		return []string{"false", "true"}
	}
	labels := make([]string, len(field.Choices))
	for i, choice := range field.Choices {
		labels[i] = choice.Label
	}
	return labels
}

func (m PageViewModel) shortcutCmd(arguments string) tea.Cmd {
	conn, session, command, generation := m.Conn, m.SessionID, m.Command, m.Generation
	return func() tea.Msg {
		prepared, err := daemon.PreparePageShortcut(context.Background(), conn, session, command, arguments)
		return pageShortcutPreparedMsg{Prepared: prepared, Err: err, Gen: generation}
	}
}
