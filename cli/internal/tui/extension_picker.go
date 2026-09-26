package tui

import (
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"fmt"
	"strings"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

type ExtensionItem struct {
	Name          string   `json:"name"`
	Description   string   `json:"description"`
	Enabled       bool     `json:"enabled"`
	Context       bool     `json:"context"`
	Tools         []string `json:"tools"`
	PythonModules []string `json:"python_modules"`
	Requires      []string `json:"requires"`
	Plugins       []string `json:"plugins"`
	// Overridden means this session has its own choice; otherwise it follows
	// GlobalEnabled, the default for sessions without one.
	Overridden    bool `json:"overridden"`
	GlobalEnabled bool `json:"global_enabled"`
}

type ExtensionPickerDoneMsg struct{}
type ExtensionPickerChangedMsg struct{}

type extensionsLoadedMsg struct {
	Extensions []ExtensionItem
	Err        error
	Gen        int
	// NoGlobal reports a daemon that predates global extension defaults.
	NoGlobal bool
}

type extensionToggledMsg struct {
	Extensions []ExtensionItem
	Err        error
	Gen        int
}

type ExtensionPickerModel struct {
	Conn       *daemon.Connection
	SessionID  string
	Extensions []ExtensionItem
	Cursor     int
	// Session scopes changes to this session; the page opens on the global
	// defaults, so a session only diverges once a change is made here.
	Session    bool
	NoGlobal   bool
	Confirming bool
	// Inheriting confirms dropping this session's choice instead of a toggle.
	Inheriting bool
	Saving     bool
	Loading    bool
	Error      string
	Generation int
	Width      int
	Height     int
	Styles     Styles
}

func NewExtensionPickerModel(conn *daemon.Connection, sessionID string) ExtensionPickerModel {
	return ExtensionPickerModel{
		Conn:      conn,
		SessionID: sessionID,
		Loading:   true,
		Styles:    DefaultStyles,
	}
}

func (m *ExtensionPickerModel) SetSize(width, height int) {
	m.Width = width
	m.Height = height
}

func (m ExtensionPickerModel) Init() tea.Cmd {
	return m.loadExtensionsCmd(m.Generation)
}

func (m ExtensionPickerModel) loadExtensionsCmd(gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return extensionsLoadedMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}

		// Check capability
		health, err := daemon.Request[struct {
			Capabilities []string `json:"capabilities"`
		}](context.Background(), m.Conn, "/health", nil)
		noGlobal := false
		if err == nil {
			hasCap := false
			noGlobal = true
			for _, c := range health.Capabilities {
				if c == "session_extensions" {
					hasCap = true
				}
				if c == "global_extensions" {
					noGlobal = false
				}
			}
			if !hasCap {
				return extensionsLoadedMsg{
					Err: errors.New("daemon upgrade needed for /extensions; when ready, run albedo daemon --stop, then albedo (this clears python variables)"),
					Gen: gen,
				}
			}
		}

		path := fmt.Sprintf("/sessions/%s/extensions", m.SessionID)
		items, err := daemon.Request[[]ExtensionItem](context.Background(), m.Conn, path, nil)
		return extensionsLoadedMsg{Extensions: items, Err: err, Gen: gen, NoGlobal: noGlobal}
	}
}

// changeExtensionCmd sends one change: scope "global" or "session" with a
// value, or "inherit" to drop this session's choice.
func (m ExtensionPickerModel) changeExtensionCmd(name, scope string, enabled bool, gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return extensionToggledMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}
		path := fmt.Sprintf("/sessions/%s/extensions", m.SessionID)
		body := map[string]any{"name": name, "scope": scope}
		if scope != "inherit" {
			body["enabled"] = enabled
		}
		if m.NoGlobal {
			// Older daemons only know session choices.
			body = map[string]any{"name": name, "enabled": enabled}
		}
		updated, err := daemon.Request[[]ExtensionItem](context.Background(), m.Conn, path, body)
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
		if msg.Gen != m.Generation {
			return m, nil
		}
		m.Loading = false
		if msg.Err != nil {
			m.Error = msg.Err.Error()
			return m, nil
		}
		m.Extensions = msg.Extensions
		m.Error = ""
		m.NoGlobal = msg.NoGlobal
		if m.NoGlobal {
			m.Session = true
		}
		if m.Cursor >= len(m.Extensions) {
			m.Cursor = max(0, len(m.Extensions)-1)
		}
		return m, nil

	case extensionToggledMsg:
		if msg.Gen != m.Generation {
			return m, nil
		}
		m.Saving = false
		if msg.Err != nil {
			m.Error = msg.Err.Error()
			return m, nil
		}
		name := ""
		if m.Cursor < len(m.Extensions) {
			name = m.Extensions[m.Cursor].Name
		}
		m.Extensions = msg.Extensions
		for i, ext := range m.Extensions {
			if ext.Name == name {
				m.Cursor = i
				break
			}
		}
		m.Confirming = false
		m.Inheriting = false
		m.Error = ""
		return m, func() tea.Msg { return ExtensionPickerChangedMsg{} }

	case tea.KeyPressMsg:
		if msg.String() == "esc" || msg.String() == "ctrl+c" || msg.String() == "ctrl+d" {
			if m.Confirming {
				m.Confirming = false
				m.Inheriting = false
				m.Error = ""
				return m, nil
			}
			return m, func() tea.Msg { return ExtensionPickerDoneMsg{} }
		}

		if m.Loading || m.Saving {
			return m, nil
		}

		if len(m.Extensions) == 0 && m.Error != "" {
			if strings.ToLower(msg.String()) == "r" {
				m.Loading = true
				m.Error = ""
				m.Generation++
				return m, m.loadExtensionsCmd(m.Generation)
			}
			return m, nil
		}

		if m.Confirming {
			if msg.String() == "enter" && len(m.Extensions) > m.Cursor {
				ext := m.Extensions[m.Cursor]
				m.Saving = true
				m.Error = ""
				m.Generation++
				switch {
				case m.Inheriting:
					return m, m.changeExtensionCmd(ext.Name, "inherit", false, m.Generation)
				case m.Session:
					return m, m.changeExtensionCmd(ext.Name, "session", !ext.Enabled, m.Generation)
				default:
					return m, m.changeExtensionCmd(ext.Name, "global", !ext.GlobalEnabled, m.Generation)
				}
			}
			return m, nil
		}

		switch msg.String() {
		case "up", "ctrl+p":
			if m.Cursor > 0 {
				m.Cursor--
			}
		case "down", "ctrl+n":
			if m.Cursor < len(m.Extensions)-1 {
				m.Cursor++
			}
		case "space", "enter":
			if len(m.Extensions) > 0 && m.Cursor < len(m.Extensions) {
				m.Error = ""
				m.Confirming = true
			}
		case "g":
			if !m.NoGlobal {
				m.Session = false
			}
		case "s":
			m.Session = true
		case "o":
			if m.Cursor < len(m.Extensions) && m.Extensions[m.Cursor].Name == "webhooks" && m.Extensions[m.Cursor].Enabled {
				return m, func() tea.Msg { return ChatOpenWebhooksPageMsg{} }
			}
		case "x":
			if m.Session && !m.NoGlobal && m.Cursor < len(m.Extensions) && m.Extensions[m.Cursor].Overridden {
				m.Error = ""
				m.Confirming = true
				m.Inheriting = true
			}
		}
	}
	return m, nil
}

func (m ExtensionPickerModel) View() string {
	var b strings.Builder

	head := func(scope string) string {
		return titleRule(m.Width, brand("albedo")+" "+m.Styles.Muted.Render("/extensions"), m.Styles.Faint.Render(scope)) + "\n"
	}
	if m.Session {
		b.WriteString(head("this session"))
		hint := "choices here apply to this session only · g global defaults"
		if m.NoGlobal {
			hint = "this daemon only supports per-session choices; restart it for global defaults"
		}
		b.WriteString(m.Styles.Faint.Render(inkWrap(hint, m.Width)))
	} else {
		b.WriteString(head("global defaults"))
		b.WriteString(m.Styles.Faint.Render(inkWrap("every session without its own choice follows these · s this session only", m.Width)))
	}
	b.WriteString("\n")
	b.WriteString(DefaultStyles.Warning.Render(ansi.Wrap("changes reload workers and available plugins, bust prompt-cache reuse, and may reset unsavable python variables", max(1, m.Width), " ")))
	b.WriteString("\n")

	if m.Error != "" {
		b.WriteString(DefaultStyles.Error.Render(m.Error))
		b.WriteString("\n")
	}

	if m.Loading {
		b.WriteString(m.Styles.Faint.Render("loading extensions…\n"))
		return b.String()
	}

	if len(m.Extensions) == 0 {
		if m.Error != "" {
			b.WriteString(keyHints(hint{"r", "retry"}, hint{"esc", "return to chat"}) + "\n")
		} else {
			b.WriteString(m.Styles.Faint.Render("no matches\nno extensions installed for this session") + "\n" + inkWrap(keyHints(hint{"↑↓", "select"}, hint{"enter/space", "toggle"}, hint{"esc", "return to chat"}), m.Width))
		}
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
		status := m.Styles.Faint.Render("off")
		if on {
			status = DefaultStyles.Success.Render("on ")
		}
		lines[i] = status + "  " + ext.Name + m.Styles.Faint.Render(scope)
		if ext.Description != "" {
			lines[i] += DefaultStyles.Faint.Render("  " + ext.Description)
		}
	}
	b.WriteString(selectableRows(lines, m.Cursor, m.Height, m.Height, m.Width, m.Styles))
	b.WriteByte('\n')

	// Current item details
	if m.Cursor < len(m.Extensions) {
		current := m.Extensions[m.Cursor]
		b.WriteString("\n")
		if current.Description != "" {
			b.WriteString(current.Description)
			b.WriteString("\n")
		}

		pluginsStr := "not reported"
		if len(current.Plugins) > 0 {
			pluginsStr = strings.Join(current.Plugins, ", ")
		}
		b.WriteString(m.Styles.Faint.Render("plugins: " + pluginsStr))
		b.WriteString("\n")

		caps := m.capabilitiesList(current)
		capsStr := "not reported"
		if len(caps) > 0 {
			capsStr = strings.Join(caps, " · ")
		}
		b.WriteString(m.Styles.Faint.Render("capabilities: " + capsStr))
		b.WriteString("\n")

		reqStr := "none"
		if len(current.Requires) > 0 {
			reqStr = strings.Join(current.Requires, ", ")
		}
		b.WriteString(m.Styles.Faint.Render("requires: " + reqStr))
		b.WriteString("\n")

		if m.Confirming {
			on := current.GlobalEnabled
			if m.Session {
				on = current.Enabled
			}
			actionWord := "enable"
			if on {
				actionWord = "disable"
			}
			choice := hint{"enter", "confirm"}
			if m.Error != "" {
				choice = hint{"enter", "retry"}
			}
			var confirmMsg string
			switch {
			case m.Inheriting:
				confirmMsg = fmt.Sprintf("drop this session's choice for %s and follow the global default?", current.Name)
			case m.Session:
				confirmMsg = fmt.Sprintf("%s %s for this session only and reload its workers?", actionWord, current.Name)
			default:
				confirmMsg = fmt.Sprintf("%s %s for every session that follows the global default?", actionWord, current.Name)
			}
			b.WriteString(DefaultStyles.Warning.Render(confirmMsg) + " " + keyHints(choice, hint{"esc", "cancel"}))
			b.WriteString("\n")
		}
	}

	if m.Saving {
		currName := "extension"
		if m.Cursor < len(m.Extensions) {
			currName = m.Extensions[m.Cursor].Name
		}
		b.WriteString(m.Styles.Faint.Render(fmt.Sprintf("reloading workers for %s…", currName)))
	} else if m.Confirming {
		b.WriteString(m.Styles.Faint.Render("waiting for confirmation"))
	} else {
		keys := []hint{{"↑↓", "select"}, {"enter/space", "toggle"}, {"s", "this session"}, {"esc", "return to chat"}}
		if m.Session {
			keys = []hint{{"↑↓", "select"}, {"enter/space", "toggle"}, {"x", "follow global"}, {"g", "global defaults"}, {"esc", "return to chat"}}
			if m.NoGlobal {
				keys = []hint{{"↑↓", "select"}, {"enter/space", "toggle"}, {"esc", "return to chat"}}
			}
		}
		if m.Cursor < len(m.Extensions) && m.Extensions[m.Cursor].Name == "webhooks" && m.Extensions[m.Cursor].Enabled {
			keys = append(keys, hint{"o", "open webhooks"})
		}
		b.WriteString(inkWrap(keyHints(keys...), m.Width))
	}

	return b.String()
}
