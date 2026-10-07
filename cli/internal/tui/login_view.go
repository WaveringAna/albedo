package tui

import (
	"albedo/cli/internal/config"
	"cmp"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func (m LoginModel) openBrowserCmd(urlStr string) tea.Cmd {
	return func() tea.Msg {
		if m.openBrowser != nil {
			m.openBrowser(urlStr)
		}
		return nil
	}
}

// inputWidth leaves the frame's margin and the field's label their room.
func (m LoginModel) inputWidth() int {
	return max(8, m.Width-10-ansi.StringWidth(m.fieldLabel()))
}

// fieldLabel is what the text input is asked for.
func (m LoginModel) fieldLabel() string {
	if m.Step == StepOAuth {
		return "callback URL or code"
	}
	label, _ := m.question()
	return label
}

// promptInput re-arms the text input for the next question and reports the
// blink command that shows its cursor. The placeholder is left as the
// previous step left it.
func (m *LoginModel) promptInput(value string, secret bool) tea.Cmd {
	m.TextInput.SetWidth(m.inputWidth())
	return ask(&m.TextInput, value, secret)
}

// fail shows an error on the current step and keeps waiting for input.
func (m LoginModel) fail(err string) (LoginModel, tea.Cmd) {
	m.Error = err
	return m, nil
}

func (m *LoginModel) SetSize(width, height int) {
	m.Width, m.Height = width, height
	m.TextInput.SetWidth(m.inputWidth())
	m.TextInput.SetValue(m.TextInput.Value())
	for _, p := range []*loginPick{&m.ChoosePicker, &m.ProtocolPicker, &m.ModelPicker} {
		p.setSize(width, height)
	}
}

// View is the login step in the list frame: a list for a choice, the
// question's input in the search line for a text step, and the step's text
// above it. Errors and progress sit in the footer.
func (m LoginModel) View() string {
	width := cmp.Or(m.Width, 80)
	title := brand("albedo") + " " + DefaultStyles.Muted.Render("/login")
	right := DefaultStyles.Faint.Render(m.Name)
	if m.Step == StepChoose {
		right = DefaultStyles.Faint.Render(config.HomeDir())
	}
	footer := m.footer(width)
	if m.listing() {
		lv := m.pickerFor().listView
		lv.Empty = "nothing to choose"
		return lv.frame(title, right, footer).view(m.Width, m.Height)
	}
	f := listFrame{
		title:  title,
		right:  right,
		filter: promptLead() + DefaultStyles.Muted.Render(m.fieldLabel()+"  ") + m.TextInput.View(),
		list:   func(w, _ int) []string { return m.body(w) },
		footer: footer,
	}
	return f.view(m.Width, m.Height)
}

// body is the text above a question: what it asks, what it takes, and what
// a sign-in or save is doing.
func (m LoginModel) body(width int) []string {
	switch m.Step {
	case StepRemove:
		kind := m.Removing.Kind
		return []string{DefaultStyles.Bold.Render(m.Removing.Label), DefaultStyles.Faint.Render(kind)}
	case StepSaving:
		state := "saving provider…"
		if m.Removing.Kind != "" {
			state = "removing " + m.Removing.Kind + "…"
		}
		return []string{DefaultStyles.Faint.Render(state)}
	case StepOAuth:
		lines := []string{DefaultStyles.Muted.Render(cmp.Or(m.Status, "starting sign-in…"))}
		if m.LoginInstructions != "" {
			lines = append(lines, paneNote(m.LoginInstructions, width)...)
		}
		if m.SignInURL != "" {
			lines = append(lines, "", DefaultStyles.Faint.Render(ansi.Hardwrap(m.SignInURL, width, true)))
		}
		lines = append(lines, "")
		return append(lines, paneNote("browser sign-in finishes on its own; paste the callback URL or code if it stalls", width)...)
	case StepModels, StepOAuthModels:
		return []string{DefaultStyles.Faint.Render("loading models…")}
	}
	_, notes := m.question()
	var lines []string
	for _, note := range notes {
		lines = append(lines, paneNote(note, width)...)
	}
	return lines
}

// question is the label a text step asks for, and what it says beside it.
func (m LoginModel) question() (string, []string) {
	switch m.Step {
	case StepName:
		var notes []string
		for _, login := range m.SignIns {
			notes = append(notes, "use "+login.Provider+" to sign in")
		}
		return "provider name", notes
	case StepBaseURL:
		if m.optionalKey() {
			return "API base URL", []string{"blank uses your daemon's environment"}
		}
		return "API base URL", nil
	case StepAPIKey:
		return "API key", nil
	case StepProject:
		return "Google Cloud project ID", nil
	case StepLocation:
		return "Vertex location", nil
	case StepModel:
		return "model ID", nil
	case StepOAuthFields:
		if m.LoginFieldIndex < len(m.LoginFields) {
			field := m.LoginFields[m.LoginFieldIndex]
			return field.Label, []string{field.Description}
		}
	}
	return "", nil
}

// hints are the keys for the step, most important first.
func (m LoginModel) hints() []hint {
	switch {
	case m.Step == StepSaving:
		return nil
	case (m.Step == StepModels || m.Step == StepOAuthModels) && !m.listing():
		return []hint{{"esc", "back"}}
	case m.listing():
		hints := []hint{{"↑↓", "move"}, {"enter", m.enterVerb()}}
		if item, ok := m.ChoosePicker.Highlighted(); ok && m.Step == StepChoose {
			if _, removable := m.removalFor(item.ID); removable {
				hints = append(hints, hint{"ctrl+d", "remove"})
			}
		}
		return append(hints, hint{"esc", "back"})
	case m.Step == StepOAuth:
		return []hint{{"enter", "submit code"}, {"esc", "cancel"}}
	case m.Step == StepAPIKey && m.Draft.APIKey != "":
		return []hint{{"enter", "keeps the saved key"}, {"esc", "cancel"}}
	}
	return []hint{{"enter", "continue"}, {"esc", "cancel"}}
}

// enterVerb says what enter does on the list the step shows.
func (m LoginModel) enterVerb() string {
	switch m.Step {
	case StepAccountProfile:
		return "use"
	case StepOAuthFlow:
		return "sign in"
	case StepModels, StepOAuthModels:
		return "use model"
	}
	return "choose"
}

// footer is the keys, with an error on a row of its own above them so the
// keys keep their labels.
func (m LoginModel) footer(width int) string {
	if m.Step == StepRemove {
		return m.confirm.footer(width, m.Error)
	}
	if m.Error != "" {
		return " " + DefaultStyles.Error.Render(ansi.Truncate(m.Error, max(1, width-2), "…")) + "\n" + footerLine(width, m.hints(), "", false)
	}
	status := ""
	if m.CatalogNote != "" && (m.Step == StepModels || m.Step == StepOAuthModels) {
		status = DefaultStyles.Faint.Render(m.CatalogNote)
	}
	return footerLine(width, m.hints(), status, false)
}
