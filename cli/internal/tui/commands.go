package tui

import (
	"albedo/cli/internal/daemon"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

type ChatCommand struct {
	Name        string
	Description string
}

var CommonCommands = []ChatCommand{
	{Name: "/a", Description: "browse sessions"},
	{Name: "/t", Description: "show or hide thinking"},
	{Name: "/v", Description: "expand or collapse code, output and diffs"},
	{Name: "/status", Description: "show state, workspace and usage"},
	{Name: "/q", Description: "quit"},
}

var AppCommands = []ChatCommand{
	{Name: "/login", Description: "add or select a named openai-compatible api"},
	{Name: "/new", Description: "new coding session"},
	{Name: "/sessions", Description: "switch session"},
	{Name: "/extensions", Description: "manage this session's extension plugins"},
	{Name: "/tree", Description: "branch this session from a history checkpoint"},
}

type CommandMenuModel struct {
	Catalog   []daemon.SessionCommand
	Selected  int
	Dismissed string
	Styles    Styles
}

func NewCommandMenuModel() CommandMenuModel {
	return CommandMenuModel{
		Styles: DefaultStyles,
	}
}

func (m *CommandMenuModel) SetCatalog(catalog []daemon.SessionCommand) {
	m.Catalog = catalog
}

func (m CommandMenuModel) Matches(input string) []ChatCommand {
	if !strings.HasPrefix(input, "/") || strings.Contains(input, "\n") || input == m.Dismissed {
		return nil
	}

	all := append([]ChatCommand{}, AppCommands...)
	for _, cmd := range m.Catalog {
		all = append(all, ChatCommand{
			Name:        cmd.Name,
			Description: cmd.Description,
		})
	}
	// Common commands appended (override if duplicate)
	for _, cmd := range CommonCommands {
		all = append(all, cmd)
	}

	// De-duplicate by name (last occurrence wins)
	seen := make(map[string]bool)
	var deduped []ChatCommand
	for i := len(all) - 1; i >= 0; i-- {
		name := all[i].Name
		if !seen[name] {
			seen[name] = true
			deduped = append([]ChatCommand{all[i]}, deduped...)
		}
	}

	var matched []ChatCommand
	for _, cmd := range deduped {
		if strings.HasPrefix(cmd.Name, input) {
			matched = append(matched, cmd)
		}
	}
	return matched
}

// OnKey handles navigation within the command popup. Returns true if consumed.
func (m *CommandMenuModel) OnKey(msg tea.KeyMsg, input string, replace func(string), submit func(string)) bool {
	matches := m.Matches(input)
	if len(matches) == 0 {
		return false
	}

	idx := m.Selected
	if idx >= len(matches) {
		idx = len(matches) - 1
	}
	if idx < 0 {
		idx = 0
	}

	switch msg.Type {
	case tea.KeyEsc:
		m.Dismissed = input
		return true
	case tea.KeyUp:
		if idx > 0 {
			m.Selected = idx - 1
		}
		return true
	case tea.KeyDown:
		if idx < len(matches)-1 {
			m.Selected = idx + 1
		}
		return true
	case tea.KeyTab:
		replace(matches[idx].Name)
		return true
	case tea.KeyEnter:
		submit(matches[idx].Name)
		return true
	default:
		m.Selected = 0
	}
	return false
}

func (m CommandMenuModel) View(input string) string {
	matches := m.Matches(input)
	if len(matches) == 0 {
		return ""
	}

	idx := m.Selected
	if idx >= len(matches) {
		idx = len(matches) - 1
	}
	if idx < 0 {
		idx = 0
	}

	start := max(0, idx-3)
	end := min(len(matches), max(4, idx+1))

	var b strings.Builder
	for i := start; i < end; i++ {
		cmd := matches[i]
		isSel := (i == idx)
		line := cmd.Name + "  " + cmd.Description
		if isSel {
			b.WriteString(m.Styles.Selected.Render(line))
		} else {
			b.WriteString(line)
		}
		b.WriteString("\n")
	}
	return b.String()
}
