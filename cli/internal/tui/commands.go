package tui

import (
	"albedo/cli/internal/daemon"
	"slices"
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
	{Name: "/link", Description: "inspect and confirm linked workspace groups"},
	{Name: "/ttl", Description: "inspect provider cache policy"},
	{Name: "/quota", Description: "inspect observed provider quota"},
	{Name: "/requests", Description: "inspect provider request diagnostics"},
	{Name: "/raise-cap", Description: "raise or restore the model context cap"},
	{Name: "/effort", Description: "choose reasoning effort"},
	{Name: "/reload", Description: "apply selected configuration and refresh models"},
	{Name: "/compact", Description: "compact durable context"},
	{Name: "/kernel", Description: "upgrade the session kernel"},
	{Name: "/model", Description: "choose a model"},
	{Name: "/context", Description: "inspect prepared context"},
	{Name: "/login", Description: "add or select a model provider"},
	{Name: "/new", Description: "start a new coding session"},
	{Name: "/sessions", Description: "switch to another session"},
	{Name: "/agents", Description: "watch and message this session's agents (ctrl+o)"},
	{Name: "/extensions", Description: "manage this session's extension plugins"},
	{Name: "/skills", Description: "manage loaded skills and per-skill defaults"},
	{Name: "/instructions", Description: "manage AGENTS.md and other instruction files"},
	{Name: "/mcp", Description: "manage MCP servers and authentication"},
	{Name: "/tree", Description: "branch this session from a history checkpoint"},
	{Name: "/cd", Description: "move this session to another folder"},
}

type CommandMenuModel struct {
	Styles    Styles
	Dismissed string
	Catalog   []daemon.SessionCommand
	Selected  int
}

func NewCommandMenuModel() CommandMenuModel {
	return CommandMenuModel{
		Styles: DefaultStyles,
	}
}

func (m CommandMenuModel) Matches(input string) []ChatCommand {
	if !strings.HasPrefix(input, "/") || strings.Contains(input, "\n") || input == m.Dismissed {
		return nil
	}

	all := slices.Clone(AppCommands)
	for _, cmd := range m.Catalog {
		all = append(all, ChatCommand{
			Name:        cmd.Name,
			Description: cmd.Description,
		})
	}
	all = append(all, CommonCommands...)

	// De-duplicate by name (last occurrence wins), placing exact match first.
	seen := make(map[string]bool, len(all))
	var direct, others []ChatCommand
	for _, cmd := range slices.Backward(all) {
		if seen[cmd.Name] {
			continue
		}
		seen[cmd.Name] = true
		if cmd.Name == input {
			direct = append(direct, cmd)
		} else if strings.HasPrefix(cmd.Name, input) {
			others = append(others, cmd)
		}
	}
	slices.Reverse(others)
	return append(direct, others...)
}

// OnKey handles navigation within the command popup. Returns true if consumed.
func (m *CommandMenuModel) OnKey(msg tea.KeyPressMsg, input string, replace func(string), submit func(string)) bool {
	matches := m.Matches(input)
	if len(matches) == 0 {
		return false
	}

	idx := max(0, min(m.Selected, len(matches)-1))

	switch msg.String() {
	case "esc":
		m.Dismissed = input
	case "up":
		if idx > 0 {
			m.Selected = idx - 1
		}
	case "down":
		if idx < len(matches)-1 {
			m.Selected = idx + 1
		}
	case "tab":
		replace(matches[idx].Name)
	case "enter":
		submit(matches[idx].Name)
	default:
		m.Selected = 0
		return false
	}
	return true
}

func (m CommandMenuModel) View(input string) string {
	matches := m.Matches(input)
	if len(matches) == 0 {
		return ""
	}

	idx := max(0, min(m.Selected, len(matches)-1))
	start := max(0, idx-3)
	end := min(len(matches), max(4, idx+1))

	var b strings.Builder
	for i := start; i < end; i++ {
		cmd := matches[i]
		desc := cmd.Name + "  " + m.Styles.Faint.Render(cmd.Description)
		if i == idx {
			b.WriteString(selectedLine(selectBar()+" "+desc, 0))
		} else {
			b.WriteString("  ")
			b.WriteString(desc)
		}
		b.WriteByte('\n')
	}
	return b.String()
}
