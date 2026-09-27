package tui

import (
	"strings"

	"albedo/cli/internal/daemon"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
)

// SessionRenameMsg asks the app to save a session's name. A blank name hands
// the title back to the daemon, which takes it from the latest message.
type SessionRenameMsg struct{ ID, Name string }

// sessionRenamedMsg is the daemon's answer to a SessionRenameMsg: the
// session as it is now listed.
type sessionRenamedMsg struct {
	SessionRenameMsg
	Session daemon.Session
	Err     error
}

// renameField edits one session's name in place. While it is open its owner
// hands it every key, so typing never reaches search or navigation.
type renameField struct {
	id, was string
	input   textinput.Model
	// selected holds until the first key: typing replaces the opening
	// draft, which a message title can fill to the limit; other keys edit it.
	selected bool
}

// renameLimit matches the daemon, which keeps 80 characters of a name.
const renameLimit = 80

// open starts a draft of current, prompting with placeholder once emptied.
func (f *renameField) open(id, current, placeholder string) {
	in := newField()
	in.CharLimit = renameLimit
	in.Placeholder = placeholder
	st := in.Styles()
	st.Focused.Text = DefaultStyles.Bold
	st.Focused.Placeholder = DefaultStyles.Faint
	in.SetStyles(st)
	in.SetValue(current)
	in.CursorEnd()
	in.Focus()
	f.id, f.was, f.input, f.selected = id, current, in, current != ""
}

func (f renameField) active() bool { return f.id != "" }

// key edits the draft. Enter saves a changed name and esc drops it; both
// close the field.
func (f *renameField) key(msg tea.KeyPressMsg) tea.Cmd {
	switch msg.String() {
	case "esc", "ctrl+c":
		f.id = ""
		return nil
	case "enter":
		id, name := f.id, strings.TrimSpace(f.input.Value())
		f.id = ""
		if name == strings.TrimSpace(f.was) {
			return nil
		}
		return func() tea.Msg { return SessionRenameMsg{ID: id, Name: name} }
	}
	if f.selected && msg.Text != "" {
		f.input.SetValue("")
	}
	f.selected = false
	var cmd tea.Cmd
	f.input, cmd = f.input.Update(msg)
	return cmd
}

// view is the draft in exactly width cells.
func (f renameField) view(width int) string {
	f.input.SetWidth(max(1, width-1))
	if f.selected {
		st := f.input.Styles()
		st.Focused.Text = DefaultStyles.Cursor
		f.input.SetStyles(st)
	}
	return svFit(f.input.View(), width)
}

// renameHints stand in for a screen's key hints while a name is being edited.
func renameHints(blank string) string {
	return keyHints(hint{"enter", "save"}, hint{"esc", "cancel"}, hint{"", "empty " + blank})
}
