package tui

import (
	"slices"
	"strings"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// form is a column of text fields with one focused; the MCP and webhook
// forms both build on it.
type form struct {
	Focus  int
	Inputs map[string]*textinput.Model
}

// newField is a text input that follows a label instead of a prompt.
func newField() textinput.Model {
	input := newTextInput()
	input.Prompt = ""
	return input
}

// ask re-arms input for the next question, masking a secret, and reports
// the blink command that shows its cursor.
func ask(input *textinput.Model, value string, secret bool) tea.Cmd {
	input.Reset()
	input.EchoMode = echo(secret)
	input.SetValue(value)
	input.Focus()
	return textinput.Blink
}

func echo(secret bool) textinput.EchoMode {
	if secret {
		return textinput.EchoPassword
	}
	return textinput.EchoNormal
}

// newForm makes a field for each key, the masked ones echoing dots, with a
// length limit no pasted secret reaches.
func newForm(keys []string, masked ...string) form {
	f := form{Inputs: map[string]*textinput.Model{}}
	for _, key := range keys {
		input := newField()
		input.CharLimit, input.EchoMode = 4096, echo(slices.Contains(masked, key))
		f.Inputs[key] = &input
	}
	return f
}

// focus focuses the field named current and blurs the rest.
func (f *form) focus(current string) {
	for key, input := range f.Inputs {
		if key == current {
			input.Focus()
		} else {
			input.Blur()
		}
	}
}

// key applies the movement keys every form shares, cycling through fields
// from first on; submit reports that the form should be saved.
func (f *form) key(msg tea.Msg, fields []string, first int) (submit, handled bool) {
	key, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return false, false
	}
	delta := 0
	switch key.String() {
	case "tab", "down":
		delta = 1
	case "shift+tab", "up":
		delta = -1
	case "ctrl+s":
		return true, true
	case "enter":
		if f.Focus == len(fields)-1 {
			return true, true
		}
		delta = 1
	default:
		return false, false
	}
	n := len(fields) - first
	f.Focus = first + (f.Focus-first+delta+n)%n
	f.focus(fields[f.Focus])
	return false, true
}

// value is a field's text without surrounding space.
func (f form) value(key string) string { return strings.TrimSpace(f.Inputs[key].Value()) }

// fit sizes the fields to the columns their rows leave for a value; a
// textinput without a width shows only the first rune of its placeholder.
func (f form) fit(width int) {
	for _, input := range f.Inputs {
		input.SetWidth(max(1, width))
	}
}

// formRow is one labelled field, marked when focused.
func formRow(focused bool, label string, pad int, value string, width int) string {
	lead := "  "
	if focused {
		lead = promptLead()
	}
	return ansi.Truncate(lead+padRight(label, pad)+value, width, "…")
}

// formFooter explains the focused field, then offers the keys every form
// shares after any of its own.
func formFooter(note string, width int, own ...hint) string {
	line := keyHints(append(own, hint{"tab/↑↓", "move"}, hint{"enter", "next"}, hint{"ctrl+s", "save"}, hint{"esc", "cancel"})...)
	if note != "" {
		line = DefaultStyles.Faint.Render(note) + DefaultStyles.Decor.Render(" · ") + line
	}
	return ansi.Truncate(line, width, "…")
}

func padRight(s string, n int) string {
	if len(s) >= n {
		return s + " "
	}
	return s + strings.Repeat(" ", n-len(s))
}
