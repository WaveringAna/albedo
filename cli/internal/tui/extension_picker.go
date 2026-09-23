package tui

import (
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"fmt"
	"github.com/charmbracelet/lipgloss"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
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
}

type ExtensionPickerDoneMsg struct{}
type ExtensionPickerChangedMsg struct{}

type extensionsLoadedMsg struct {
	Extensions []ExtensionItem
	Err        error
	Gen        int
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
	Confirming bool
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
		if err == nil {
			hasCap := false
			for _, c := range health.Capabilities {
				if c == "session_extensions" {
					hasCap = true
					break
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
		return extensionsLoadedMsg{Extensions: items, Err: err, Gen: gen}
	}
}

func (m ExtensionPickerModel) toggleExtensionCmd(name string, enabled bool, gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return extensionToggledMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}
		path := fmt.Sprintf("/sessions/%s/extensions", m.SessionID)
		body := map[string]any{"name": name, "enabled": enabled}
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
		m.Error = ""
		return m, func() tea.Msg { return ExtensionPickerChangedMsg{} }

	case tea.KeyMsg:
		if msg.Type == tea.KeyEsc || (msg.Type == tea.KeyCtrlC || msg.Type == tea.KeyCtrlD) {
			if m.Confirming {
				m.Confirming = false
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
			if msg.Type == tea.KeyEnter && len(m.Extensions) > m.Cursor {
				ext := m.Extensions[m.Cursor]
				m.Saving = true
				m.Error = ""
				m.Generation++
				return m, m.toggleExtensionCmd(ext.Name, !ext.Enabled, m.Generation)
			}
			return m, nil
		}

		switch msg.Type {
		case tea.KeyUp, tea.KeyCtrlP:
			if m.Cursor > 0 {
				m.Cursor--
			}
		case tea.KeyDown, tea.KeyCtrlN:
			if m.Cursor < len(m.Extensions)-1 {
				m.Cursor++
			}
		case tea.KeySpace, tea.KeyEnter:
			if len(m.Extensions) > 0 && m.Cursor < len(m.Extensions) {
				m.Error = ""
				m.Confirming = true
			}
		}
	}
	return m, nil
}

func (m ExtensionPickerModel) View() string {
	var b strings.Builder

	b.WriteString("albedo /extensions · session plugins")
	b.WriteString("\n")
	b.WriteString(m.Styles.Dim.Render("extensions bundle plugins for this session only"))
	b.WriteString("\n")
	b.WriteString(inkYellow.Render(ansi.Wrap("changes reload workers and available plugins, bust prompt-cache reuse, and may reset unsavable python variables", max(1, m.Width), " ")))
	b.WriteString("\n")

	if m.Error != "" {
		b.WriteString(inkRed.Render(m.Error))
		b.WriteString("\n")
	}

	if m.Loading {
		b.WriteString(m.Styles.Dim.Render("loading extensions…\n"))
		return b.String()
	}

	if len(m.Extensions) == 0 {
		if m.Error != "" {
			b.WriteString(m.Styles.Dim.Render("r retry · esc return to chat\n"))
		} else {
			b.WriteString(m.Styles.Dim.Render("no matches\nno extensions installed for this session\n" + inkWrap("↑↓ select · enter/space toggle · esc return to chat", m.Width)))
		}
		return b.String()
	}

	lines := make([]string, len(m.Extensions))
	for i, ext := range m.Extensions {
		status := "off"
		if ext.Enabled {
			status = inkGreen.Render("on ")
		}
		lines[i] = status + "  " + ext.Name
		if ext.Description != "" {
			lines[i] += lipgloss.NewStyle().Faint(true).Render("  " + ext.Description)
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
		b.WriteString(m.Styles.Dim.Render("plugins: " + pluginsStr))
		b.WriteString("\n")

		caps := m.capabilitiesList(current)
		capsStr := "not reported"
		if len(caps) > 0 {
			capsStr = strings.Join(caps, " · ")
		}
		b.WriteString(m.Styles.Dim.Render("capabilities: " + capsStr))
		b.WriteString("\n")

		reqStr := "none"
		if len(current.Requires) > 0 {
			reqStr = strings.Join(current.Requires, ", ")
		}
		b.WriteString(m.Styles.Dim.Render("requires: " + reqStr))
		b.WriteString("\n")

		if m.Confirming {
			actionWord := "enable"
			if current.Enabled {
				actionWord = "disable"
			}
			choice := "enter confirm"
			if m.Error != "" {
				choice = "enter retry"
			}
			confirmMsg := fmt.Sprintf("%s %s and reload this session's workers? %s · esc cancel", actionWord, current.Name, choice)
			b.WriteString(inkYellow.Render(confirmMsg))
			b.WriteString("\n")
		}
	}

	if m.Saving {
		currName := "extension"
		if m.Cursor < len(m.Extensions) {
			currName = m.Extensions[m.Cursor].Name
		}
		b.WriteString(m.Styles.Dim.Render(fmt.Sprintf("reloading workers for %s…", currName)))
	} else if m.Confirming {
		b.WriteString(m.Styles.Dim.Render("waiting for confirmation"))
	} else {
		b.WriteString(m.Styles.Dim.Render(inkWrap("↑↓ select · enter/space toggle · esc return to chat", m.Width)))
	}

	return b.String()
}
