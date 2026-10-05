package tui

import (
	"albedo/cli/internal/config"
	"cmp"
	"strings"

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

func (m LoginModel) inputWidth() int {
	// Ink includes its cursor cell in width; Bubbles tracks the cursor separately.
	if m.Step == StepOAuth {
		return max(8, m.Width-25)
	}
	return max(8, m.Width-19)
}

// promptInput re-arms the text input for the next question and reports the
// blink command that shows its cursor. The placeholder is left as the
// previous step left it.
func (m *LoginModel) promptInput(value string, secret bool) tea.Cmd {
	m.TextInput.SetWidth(m.inputWidth())
	return ask(&m.TextInput, value, secret)
}

// pickerFor returns the picker the current step drives.
func (m *LoginModel) pickerFor() *PickerModel {
	switch m.Step {
	case StepProtocol:
		return &m.ProtocolPicker
	case StepRemove:
		return &m.ConfirmPicker
	case StepModels, StepOAuthModels:
		return &m.ModelPicker
	}
	return &m.ChoosePicker
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
	for _, p := range []*PickerModel{&m.ChoosePicker, &m.ProtocolPicker, &m.ModelPicker, &m.ConfirmPicker} {
		p.SetSize(width, height)
	}
}

func (m LoginModel) View() string {
	var b strings.Builder
	line := func(s string) {
		b.WriteString(s)
		b.WriteByte('\n')
	}
	line(titleRule(m.Width, brand("albedo")+" "+m.Styles.Muted.Render("/login"), m.Styles.Faint.Render(m.Name)))
	location := "Provider configuration stored in " + config.HomeDir()
	if m.Width > 0 && ansi.StringWidth(location) > m.Width && ansi.StringWidth(config.HomeDir()) <= m.Width {
		location = "Provider configuration stored in\n" + config.HomeDir()
	}
	line(m.Styles.Faint.Render(ansi.Wrap(location, m.Width, "")))
	if m.Error != "" {
		line(m.Styles.Error.Render(ansi.Wrap(m.Error, m.Width, "")))
	}

	switch m.Step {
	case StepChoose, StepAccountProfile, StepOAuthFlow:
		line(m.ChoosePicker.View())
		b.WriteString(ansi.Wrap(keyHints(hint{"enter", "select"}, hint{"d", "remove"}, hint{"esc", "cancel"}), m.Width, ""))
	case StepProtocol:
		b.WriteString(m.ProtocolPicker.View())
	case StepRemove:
		b.WriteString(m.ConfirmPicker.View())
	case StepModels, StepOAuthModels:
		if m.Catalog == nil {
			b.WriteString(m.Styles.Faint.Render("loading models…"))
			break
		}
		if m.CatalogNote != "" {
			line(m.Styles.Faint.Render(m.CatalogNote))
		}
		b.WriteString(m.ModelPicker.View())
	case StepOAuthFields:
		if m.LoginFieldIndex < len(m.LoginFields) {
			field := m.LoginFields[m.LoginFieldIndex]
			if field.Type == "choice" || field.Type == "boolean" {
				line(m.ChoosePicker.View())
			} else {
				line(field.Label)
				if field.Description != "" {
					line(m.Styles.Faint.Render(field.Description))
				}
				line(m.TextInput.View())
				b.WriteString(keyHints(hint{"enter", "continue"}, hint{"esc", "cancel"}))
			}
		}
	case StepOAuth:
		line(cmp.Or(m.Status, "starting sign-in…"))
		if m.LoginInstructions != "" {
			line(m.Styles.Faint.Render(ansi.Wrap(m.LoginInstructions, m.Width, "")))
		}
		if m.SignInURL != "" {
			line(m.Styles.Faint.Render(ansi.Hardwrap(m.SignInURL, m.Width, true)))
		}
		b.WriteString("Callback URL or code: ")
		line(m.TextInput.View())
		b.WriteString(ansi.Wrap(m.Styles.Faint.Render("Browser sign-in completes automatically")+m.Styles.Decor.Render(" · ")+keyHints(hint{"enter", "submit code"}, hint{"esc", "cancel"}), m.Width, ""))
	case StepSaving:
		state := "saving provider…"
		if m.Removing.Kind != "" {
			state = "removing " + m.Removing.Kind + "…"
		}
		b.WriteString(m.Styles.Faint.Render(state))
	default:
		stepLabels := map[LoginStep]string{
			StepName: "provider name", StepBaseURL: "API base URL",
			StepAPIKey: "API key", StepModel: "model ID",
			StepProject: "Google Cloud project ID", StepLocation: "Vertex location",
		}
		line(stepLabels[m.Step] + ": " + m.TextInput.View())
		var hints []hint
		if m.Step == StepAPIKey && m.Draft.APIKey != "" {
			hints = append(hints, hint{"enter", "keeps the saved key"})
		}
		if m.Step == StepName {
			for _, login := range m.SignIns {
				hints = append(hints, hint{"", "use " + login.Provider + " to sign in"})
			}
		}
		hints = append(hints, hint{"enter", "continue"}, hint{"esc", "cancel"})
		b.WriteString(ansi.Wrap(keyHints(hints...), m.Width, ""))
	}
	return b.String()
}
