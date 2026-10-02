package tui

import (
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strings"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

type ExtensionItem = daemon.ExtensionSummary

type ExtensionPickerDoneMsg struct{}
type ExtensionPickerChangedMsg struct{}

type extensionsLoadedMsg struct {
	Err        error
	Extensions []ExtensionItem
	Gen        int
}

type extensionToggledMsg struct {
	Err        error
	Extensions []ExtensionItem
	Gen        int
}

type ExtensionPickerModel struct {
	Styles     Styles
	Conn       *daemon.Connection
	SessionID  string
	Extensions []ExtensionItem
	page
	// Session scopes changes to this session; the page opens on the global
	// defaults, so a session only diverges once a change is made here.
	Session    bool
	Confirming bool
	// Inheriting confirms dropping this session's choice instead of a toggle.
	Inheriting bool
}

func NewExtensionPickerModel(conn *daemon.Connection, sessionID string) ExtensionPickerModel {
	return ExtensionPickerModel{
		Conn:      conn,
		SessionID: sessionID,
		page:      page{Loading: true},
		Styles:    DefaultStyles,
	}
}

func (m ExtensionPickerModel) Init() tea.Cmd {
	return m.loadExtensionsCmd(m.Generation)
}

func (m ExtensionPickerModel) loadExtensionsCmd(gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return extensionsLoadedMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}

		path := fmt.Sprintf("/sessions/%s/extensions", m.SessionID)
		items, err := daemon.RequestOperation[[]ExtensionItem](context.Background(), m.Conn, daemon.Operation{Name: "load extensions", Method: http.MethodGet, Path: path, Body: nil, Policy: daemon.ReadRecovery})
		return extensionsLoadedMsg{Extensions: items, Err: err, Gen: gen}
	}
}

// changeExtensionCmd sends one change: scope "global" or "session" with a
// value, or "inherit" to drop this session's choice.
func (m ExtensionPickerModel) changeExtensionCmd(name, scope string, enabled bool, gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return extensionToggledMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}
		body := map[string]any{"name": name, "scope": scope}
		if scope != "inherit" {
			body["enabled"] = enabled
		}
		updated, err := daemon.SelectExtension(context.Background(), m.Conn, m.SessionID, body)
		return extensionToggledMsg{Extensions: updated, Err: err, Gen: gen}
	}
}

func (m ExtensionPickerModel) capabilitiesList(ext ExtensionItem) []string {
	var caps []string
	if ext.Context {
		caps = append(caps, "context")
	}
	if len(ext.Tools) > 0 {
		caps = append(caps, fmt.Sprintf("tools (%s)", strings.Join(ext.Tools, ", ")))
	}
	if len(ext.PythonModules) > 0 {
		caps = append(caps, fmt.Sprintf("python modules (%s)", strings.Join(ext.PythonModules, ", ")))
	}
	return caps
}

func (m ExtensionPickerModel) Update(msg tea.Msg) (ExtensionPickerModel, tea.Cmd) {
	switch msg := msg.(type) {
	case extensionsLoadedMsg:
		if !m.settle(msg.Gen, msg.Err, &m.Loading) {
			return m, nil
		}
		m.Extensions = msg.Extensions
		m.Error = ""
		if m.Cursor >= len(m.Extensions) {
			m.Cursor = max(0, len(m.Extensions)-1)
		}
		return m, nil

	case extensionToggledMsg:
		if !m.settle(msg.Gen, msg.Err, &m.Saving) {
			return m, nil
		}
		name := ""
		if m.Cursor < len(m.Extensions) {
			name = m.Extensions[m.Cursor].Name
		}
		m.Extensions = msg.Extensions
		if idx := slices.IndexFunc(m.Extensions, func(e ExtensionItem) bool { return e.Name == name }); idx >= 0 {
			m.Cursor = idx
		}
		m.Confirming, m.Inheriting, m.Error = false, false, ""
		return m, func() tea.Msg { return ExtensionPickerChangedMsg{} }

	case tea.KeyPressMsg:
		switch msg.String() {
		case "esc", "ctrl+c", "ctrl+d":
			if m.Confirming {
				m.Confirming, m.Inheriting, m.Error = false, false, ""
				return m, nil
			}
			return m, func() tea.Msg { return ExtensionPickerDoneMsg{} }
		}

		if m.Loading || m.Saving {
			return m, nil
		}

		if len(m.Extensions) == 0 && m.Error != "" {
			if strings.EqualFold(msg.String(), "r") {
				m.Loading, m.Error = true, ""
				m.Generation++
				return m, m.loadExtensionsCmd(m.Generation)
			}
			return m, nil
		}

		if m.Confirming {
			if msg.String() == "enter" && len(m.Extensions) > m.Cursor {
				ext := m.Extensions[m.Cursor]
				m.Saving, m.Error = true, ""
				m.Generation++
				scope, val := "global", !ext.GlobalEnabled
				if m.Inheriting {
					scope, val = "inherit", false
				} else if m.Session {
					scope, val = "session", !ext.Enabled
				}
				return m, m.changeExtensionCmd(ext.Name, scope, val, m.Generation)
			}
			return m, nil
		}

		if m.step(msg.String(), len(m.Extensions)) {
			return m, nil
		}
		switch msg.String() {
		case "space", "enter":
			if len(m.Extensions) > 0 && m.Cursor < len(m.Extensions) {
				if reason := m.Extensions[m.Cursor].Quarantined; reason != "" {
					m.Error = reason
					return m, nil
				}
				m.Error = ""
				m.Confirming = true
			}
		case "g":
			m.Session = false
		case "s":
			m.Session = true
		case "o":
			if m.Cursor < len(m.Extensions) && m.Extensions[m.Cursor].Name == "webhooks" && m.Extensions[m.Cursor].Enabled {
				return m, func() tea.Msg { return ChatOpenWebhooksPageMsg{} }
			}
		case "x":
			if m.Session && m.Cursor < len(m.Extensions) && m.Extensions[m.Cursor].Overridden {
				m.Error = ""
				m.Confirming, m.Inheriting = true, true
			}
		}
	}
	return m, nil
}

func (m ExtensionPickerModel) View() string {
	var b strings.Builder

	scope, note := "global defaults", "Sessions without their own choice use these defaults · s to change this session only"
	if m.Session {
		scope, note = "this session", "Changes here affect only this session · g to edit global defaults"
	}
	b.WriteString(titleRule(m.Width, brand("albedo")+" "+m.Styles.Muted.Render("/extensions"), m.Styles.Faint.Render(scope)))
	b.WriteByte('\n')
	b.WriteString(m.Styles.Faint.Render(inkWrap(note, m.Width)))
	b.WriteByte('\n')
	b.WriteString(DefaultStyles.Warning.Render(ansi.Wrap("Changes reload the affected sessions, prevent reuse of cached prompts, and may lose Python variables that cannot be saved.", max(1, m.Width), " ")))
	b.WriteByte('\n')

	if m.Error != "" {
		b.WriteString(DefaultStyles.Error.Render(m.Error))
		b.WriteByte('\n')
	}

	if m.Loading {
		b.WriteString(m.Styles.Faint.Render("loading extensions…\n"))
		return b.String()
	}

	if len(m.Extensions) == 0 {
		if m.Error != "" {
			b.WriteString(keyHints(hint{"r", "retry"}, hint{"esc", "return to chat"}))
			b.WriteByte('\n')
		} else {
			b.WriteString(m.Styles.Faint.Render("No extensions are available for this session."))
			b.WriteByte('\n')
			b.WriteString(inkWrap(keyHints(hint{"↑↓", "select"}, hint{"enter/space", "toggle"}, hint{"esc", "return to chat"}), m.Width))
		}
		return b.String()
	}

	if !m.Saving && m.Confirming && m.Cursor < len(m.Extensions) {
		current := m.Extensions[m.Cursor]
		on := current.GlobalEnabled
		if m.Session {
			on = current.Enabled
		}
		actionWord := "Enable"
		if on {
			actionWord = "Disable"
		}
		choice := hint{"enter", "confirm"}
		if m.Error != "" {
			choice = hint{"enter", "retry"}
		}
		var confirmMsg string
		switch {
		case m.Inheriting:
			confirmMsg = fmt.Sprintf("This session will follow the global default for %s. Remove its own choice?", current.Name)
		case m.Session:
			confirmMsg = fmt.Sprintf("This will reload this session. %s %s for this session only?", actionWord, current.Name)
		default:
			confirmMsg = fmt.Sprintf("Sessions following global defaults will use this change. %s %s globally?", actionWord, current.Name)
		}
		for line := range strings.SplitSeq(ansi.Wrap(confirmMsg, max(1, m.Width), " "), "\n") {
			b.WriteString(DefaultStyles.Warning.Render(line))
			b.WriteByte('\n')
		}
		b.WriteString(inkWrap(keyHints(choice, hint{"esc", "cancel"}), m.Width))
		b.WriteByte('\n')
		return b.String()
	}

	lines := make([]string, len(m.Extensions))
	for i, ext := range m.Extensions {
		on, scope := ext.GlobalEnabled, ""
		if m.Session {
			on, scope = ext.Enabled, "  follows global"
			if ext.Overridden {
				scope = "  this session"
			}
		} else if ext.Overridden {
			state := "off"
			if ext.Enabled {
				state = "on"
			}
			scope = "  this session: " + state
		}
		var status string
		switch {
		case ext.Quarantined != "":
			status, scope = DefaultStyles.Error.Render("bad"), "  quarantined"
		case on:
			status = DefaultStyles.Success.Render("on ")
		default:
			status = m.Styles.Faint.Render("off")
		}
		line := status + "  " + ext.Name + m.Styles.Faint.Render(scope)
		if ext.Description != "" {
			line += DefaultStyles.Faint.Render("  " + ext.Description)
		}
		lines[i] = line
	}
	b.WriteString(selectableRows(lines, m.Cursor, m.Height, m.Height, m.Width, m.Styles))
	b.WriteByte('\n')

	// Current item details
	if m.Cursor < len(m.Extensions) {
		current := m.Extensions[m.Cursor]
		b.WriteByte('\n')
		if current.Description != "" {
			b.WriteString(current.Description)
			b.WriteByte('\n')
		}

		joinOr := func(items []string, sep, empty string) string {
			if len(items) == 0 {
				return empty
			}
			return strings.Join(items, sep)
		}
		b.WriteString(m.Styles.Faint.Render("plugins: " + joinOr(current.Plugins, ", ", "not reported")))
		b.WriteByte('\n')
		b.WriteString(m.Styles.Faint.Render("capabilities: " + joinOr(m.capabilitiesList(current), " · ", "not reported")))
		b.WriteByte('\n')
		b.WriteString(m.Styles.Faint.Render("requires: " + joinOr(current.Requires, ", ", "none")))
		b.WriteByte('\n')
		if current.Quarantined != "" {
			b.WriteString(DefaultStyles.Error.Render(inkWrap("quarantined: "+current.Quarantined, m.Width)))
			b.WriteByte('\n')
		}

	}

	if m.Saving {
		currName := "extension"
		if m.Cursor < len(m.Extensions) {
			currName = m.Extensions[m.Cursor].Name
		}
		b.WriteString(m.Styles.Faint.Render(fmt.Sprintf("Reloading %s…", currName)))
	} else if m.Confirming {
		b.WriteString(m.Styles.Faint.Render("waiting for confirmation"))
	} else {
		keys := []hint{{"↑↓", "select"}, {"enter/space", "toggle"}}
		if !m.Session {
			keys = append(keys, hint{"s", "this session"})
		} else {
			keys = append(keys, hint{"x", "follow global"}, hint{"g", "global defaults"})
		}
		keys = append(keys, hint{"esc", "return to chat"})
		if m.Cursor < len(m.Extensions) && m.Extensions[m.Cursor].Name == "webhooks" && m.Extensions[m.Cursor].Enabled {
			keys = append(keys, hint{"o", "open webhooks"})
		}
		b.WriteString(inkWrap(keyHints(keys...), m.Width))
	}

	return b.String()
}
