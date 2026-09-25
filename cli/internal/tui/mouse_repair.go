package tui

import (
	"regexp"
	"strconv"

	tea "github.com/charmbracelet/bubbletea"
)

// sgrTail is what remains of an SGR mouse report once its "ESC [" was
// consumed on its own: "<button;x;y" and M (press) or m (release).
var sgrTail = regexp.MustCompile(`^<(\d+);(\d+);(\d+)([Mm])$`)

// RepairSplitMouse is a program filter that rebuilds mouse reports Bubble
// Tea v1 splits. Its reader parses 256-byte reads; when input backs up and a
// read ends inside "ESC[<64;19;5M", the "ESC[" becomes an Alt+[ key and the
// rest arrives as typed runes, so scrolling types "[<64;19;5M" into the input.
// The pair is turned back into the mouse event. A lone Alt+[ is dropped: it
// has no binding, and macOS Option+[ arrives as a character, not as Alt.
func RepairSplitMouse() func(tea.Model, tea.Msg) tea.Msg {
	held := false
	return func(_ tea.Model, msg tea.Msg) tea.Msg {
		key, isKey := msg.(tea.KeyMsg)
		if isKey && key.Alt && key.Type == tea.KeyRunes && len(key.Runes) == 1 && key.Runes[0] == '[' {
			held = true
			return nil
		}
		if !held {
			return msg
		}
		held = false
		if isKey && key.Type == tea.KeyRunes && !key.Alt {
			if mouse, ok := parseSGRTail(string(key.Runes)); ok {
				return mouse
			}
		}
		return msg
	}
}

// parseSGRTail decodes "<b;x;y" + M/m as Bubble Tea's SGR parser does.
func parseSGRTail(s string) (tea.MouseMsg, bool) {
	m := sgrTail.FindStringSubmatch(s)
	if m == nil {
		return tea.MouseMsg{}, false
	}
	b, err1 := strconv.Atoi(m[1])
	x, err2 := strconv.Atoi(m[2])
	y, err3 := strconv.Atoi(m[3])
	if err1 != nil || err2 != nil || err3 != nil {
		return tea.MouseMsg{}, false
	}
	const (
		bitShift  = 0b0000_0100
		bitAlt    = 0b0000_1000
		bitCtrl   = 0b0001_0000
		bitMotion = 0b0010_0000
		bitWheel  = 0b0100_0000
		bitAdd    = 0b1000_0000
		bitsMask  = 0b0000_0011
	)
	var e tea.MouseEvent
	switch {
	case b&bitAdd != 0:
		e.Button = tea.MouseButtonBackward + tea.MouseButton(b&bitsMask)
	case b&bitWheel != 0:
		e.Button = tea.MouseButtonWheelUp + tea.MouseButton(b&bitsMask)
	default:
		e.Button = tea.MouseButtonLeft + tea.MouseButton(b&bitsMask)
		if b&bitsMask == bitsMask {
			e.Action = tea.MouseActionRelease
			e.Button = tea.MouseButtonNone
		}
	}
	if b&bitMotion != 0 && !e.IsWheel() {
		e.Action = tea.MouseActionMotion
	}
	if m[4] == "m" && e.Action != tea.MouseActionMotion && !e.IsWheel() {
		e.Action = tea.MouseActionRelease
	}
	e.Alt, e.Ctrl, e.Shift = b&bitAlt != 0, b&bitCtrl != 0, b&bitShift != 0
	e.X, e.Y = x-1, y-1
	switch {
	case e.Button == tea.MouseButtonWheelUp:
		e.Type = tea.MouseWheelUp
	case e.Button == tea.MouseButtonWheelDown:
		e.Type = tea.MouseWheelDown
	case e.Action == tea.MouseActionRelease:
		e.Type = tea.MouseRelease
	case e.Action == tea.MouseActionMotion:
		e.Type = tea.MouseMotion
	case e.Button == tea.MouseButtonLeft:
		e.Type = tea.MouseLeft
	}
	return tea.MouseMsg(e), true
}
