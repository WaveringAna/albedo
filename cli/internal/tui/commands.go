package tui

import (
	"albedo/cli/internal/daemon"
	"strings"

	tea "charm.land/bubbletea/v2"
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
	{Name: "/agents", Description: "watch and message this session's agents (ctrl+o)"},
	{Name: "/extensions", Description: "manage this session's extension plugins"},
	{Name: "/skills", Description: "manage loaded skills and per-skill defaults"},
	{Name: "/instructions", Description: "manage AGENTS.md and other instruction files"},
	{Name: "/mcp", Description: "manage MCP servers and authentication"},
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

	var direct []ChatCommand
	var others []ChatCommand
	for _, cmd := range deduped {
		if cmd.Name == input {
			direct = append(direct, cmd)
		} else if strings.HasPrefix(cmd.Name, input) {
			others = append(others, cmd)
		}
	}
	return append(direct, others...)
}

// OnKey handles navigation within the command popup. Returns true if consumed.
func (m *CommandMenuModel) OnKey(msg tea.KeyPressMsg, input string, replace func(string), submit func(string)) bool {
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

	switch msg.String() {
	case "esc":
		m.Dismissed = input
		return true
	case "up":
		if idx > 0 {
			m.Selected = idx - 1
		}
		return true
	case "down":
		if idx < len(matches)-1 {
			m.Selected = idx + 1
		}
		return true
	case "tab":
		replace(matches[idx].Name)
		return true
	case "enter":
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
		line := "  " + cmd.Name + "  " + m.Styles.Faint.Render(cmd.Description)
		if isSel {
			line = selectedLine(selectBar()+" "+cmd.Name+"  "+m.Styles.Faint.Render(cmd.Description), 0)
		}
		b.WriteString(line)
		b.WriteString("\n")
	}
	return b.String()
}
