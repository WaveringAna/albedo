package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
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
	Conn          *daemon.Connection
	Doc           *PageDocument
	CurrentAction *PageAction
	SessionID     string
	Command       string
	TextInput     textinput.Model
	pageStatus
	listView
	confirm
	Mode                    pageModeKind
	ChoiceIndex             int
	FieldIndex, ActionIndex int
	FormValues              map[string]json.RawMessage
	Busy                    bool
}

func NewPageViewModel(conn *daemon.Connection, sessionID, command string) PageViewModel {
	return PageViewModel{
		Conn:       conn,
		SessionID:  sessionID,
		Command:    command,
		TextInput:  newField(),
		pageStatus: newPageStatus(false),
		listView:   newListView("Search " + strings.TrimPrefix(command, "/")),
		Busy:       true,
	}
}

func (m *PageViewModel) SetSize(width, height int) {
	m.pageStatus.SetSize(width, height)
	m.listView.setSize(width, height)
	m.TextInput.SetWidth(max(10, width-20))
}

func (m PageViewModel) Init() tea.Cmd {
	return m.loadPageCmd(m.Generation)
}

// Confirming reports a question waiting for enter or esc.
func (m PageViewModel) Confirming() bool { return m.confirm.asking() }

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

// currentRow is the row under the cursor, nil when none is shown.
func (m PageViewModel) currentRow() *PageRow {
	row, ok := m.highlighted()
	if !ok || m.Doc == nil {
		return nil
	}
	i := slices.IndexFunc(m.Doc.Rows, func(r PageRow) bool { return r.ID == row.key })
	if i < 0 {
		return nil
	}
	return &m.Doc.Rows[i]
}

// target names the row an action applies to, for the question and prompt.
func (m PageViewModel) target(act PageAction) string {
	row := m.currentRow()
	if !act.Row || row == nil {
		return ""
	}
	target := " "
	if id := rowID(*row); id != "" {
		target += id + " "
	}
	return target + row.Text
}

// ask opens act's question; enter in it runs the action and esc drops it.
func (m *PageViewModel) ask(act PageAction) {
	m.Notice, m.Error = "", ""
	m.CurrentAction, m.Mode = &act, modeConfirm
	target := m.target(act)
	m.confirm.ask(act.ID, target, act.Label, cmp.Or(act.Confirmation, act.Label+target+"?"))
}

// cancelPrompt drops whatever a prompt or question was collecting.
func (m *PageViewModel) cancelPrompt() {
	m.Mode, m.CurrentAction, m.FormValues, m.FieldIndex = modeBrowse, nil, nil, 0
	m.TextInput.Reset()
	m.confirm.dismiss()
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
		m.setDoc(msg.Doc)
		m.Error = ""
		return m, nil

	case pageShortcutPreparedMsg:
		if !m.settle(msg.Gen, msg.Err, &m.Busy) {
			return m, nil
		}
		prepared := msg.Prepared
		m.setDoc(prepared.Page)
		m.Error = ""
		if prepared.Request.Row != nil {
			m.focusRow(prepared.Request.Row.ID)
		}
		act := prepared.Request.Action
		if act.Confirm {
			m.ask(act)
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
			m.setDoc(msg.Prepared)
			m.Cursor = 0
			m.Mode, m.Busy, m.CurrentAction = modeBrowse, false, nil
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
		return m.keyPress(msg)
	}
	if m.Mode == modeText {
		var cmd tea.Cmd
		m.TextInput, cmd = m.TextInput.Update(msg)
		return m, cmd
	}
	cmd := m.listView.update(msg)
	return m, cmd
}

// keyPress routes a key by the mode the page is in. A bare letter only ever
// reaches the filter or a prompt; actions run from chords.
func (m PageViewModel) keyPress(msg tea.KeyPressMsg) (PageViewModel, tea.Cmd) {
	key := msg.String()
	if m.Mode == modeConfirm {
		if m.confirm.key(msg) {
			act := *m.CurrentAction
			m.CurrentAction, m.Mode = nil, modeBrowse
			m.confirm.dismiss()
			cmd := m.beginAction(act, false)
			return m, cmd
		}
		if !m.confirm.asking() {
			m.CurrentAction, m.Mode = nil, modeBrowse
		}
		return m, nil
	}
	if key == "esc" || key == "ctrl+c" {
		if m.Mode == modeBrowse {
			return m, func() tea.Msg { return PageCancelMsg{} }
		}
		m.cancelPrompt()
		return m, nil
	}
	if m.Busy {
		return m, nil
	}
	switch m.Mode {
	case modeText:
		if key != "enter" {
			var cmd tea.Cmd
			m.TextInput, cmd = m.TextInput.Update(msg)
			return m, cmd
		}
		if m.CurrentAction == nil {
			return m, nil
		}
		act, val := *m.CurrentAction, m.TextInput.Value()
		m.TextInput.Reset()
		cmd := m.runAction(act, val)
		return m, cmd
	case modeChoice:
		return m.choiceKey(key)
	case modeActions:
		return m.actionsKey(key)
	}
	return m.browseKey(msg)
}

// browseKey runs a chord, opens the menu, reloads, or moves and types in the
// filter.
func (m PageViewModel) browseKey(msg tea.KeyPressMsg) (PageViewModel, tea.Cmd) {
	key := msg.String()
	if key == "ctrl+r" {
		m.Busy, m.Error = true, ""
		m.Generation = nextPageGeneration()
		return m, m.loadPageCmd(m.Generation)
	}
	if m.Doc == nil {
		return m, nil
	}
	if key == "ctrl+a" {
		if len(m.Doc.Actions) > 0 {
			m.Mode, m.ActionIndex = modeActions, 0
		}
		return m, nil
	}
	if act, ok := m.chord(key); ok {
		if act.Confirm {
			m.ask(act)
			return m, nil
		}
		cmd := m.beginAction(act, true)
		return m, cmd
	}
	cmd := m.listView.update(msg)
	return m, cmd
}

// chord is the action bound to key that applies to the row under the cursor.
func (m PageViewModel) chord(key string) (PageAction, bool) {
	for _, act := range m.Doc.Actions {
		if act.Key == key && (!act.Row || m.currentRow() != nil) {
			return act, true
		}
	}
	return PageAction{}, false
}

// actionsKey moves through the actions menu and runs the one entered on.
func (m PageViewModel) actionsKey(key string) (PageViewModel, tea.Cmd) {
	switch key {
	case "up", "ctrl+p":
		m.ActionIndex = max(0, m.ActionIndex-1)
	case "down", "ctrl+n":
		m.ActionIndex = min(len(m.Doc.Actions)-1, m.ActionIndex+1)
	case "enter":
		act := m.Doc.Actions[m.ActionIndex]
		if act.Row && m.currentRow() == nil {
			m.Error = "Select a row for this action."
			return m, nil
		}
		m.Mode = modeBrowse
		if act.Confirm {
			m.ask(act)
			return m, nil
		}
		cmd := m.beginAction(act, true)
		return m, cmd
	}
	return m, nil
}

// choiceKey moves through a choice field's options and applies the one chosen.
func (m PageViewModel) choiceKey(key string) (PageViewModel, tea.Cmd) {
	opts := m.fieldChoices()
	if len(opts) == 0 {
		return m, nil
	}
	switch key {
	case "left", "up":
		m.ChoiceIndex = (m.ChoiceIndex - 1 + len(opts)) % len(opts)
	case "right", "down":
		m.ChoiceIndex = (m.ChoiceIndex + 1) % len(opts)
	case "enter":
		cmd := m.runAction(*m.CurrentAction, opts[m.ChoiceIndex])
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
