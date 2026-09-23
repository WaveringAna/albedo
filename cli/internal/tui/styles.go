package tui

import "github.com/charmbracelet/lipgloss"

type Styles struct {
	Faint        lipgloss.Style
	Dim          lipgloss.Style
	Bold         lipgloss.Style
	Prompt       lipgloss.Style
	PromptBright lipgloss.Style
	Error        lipgloss.Style
	Warning      lipgloss.Style
	ChatWarning  lipgloss.Style
	ChatSuccess  lipgloss.Style
	Success      lipgloss.Style
	Header       lipgloss.Style
	Selected     lipgloss.Style
	Unselected   lipgloss.Style
	Detail       lipgloss.Style
	Thinking     lipgloss.Style
	ToolName     lipgloss.Style
	ToolDetail   lipgloss.Style
	DiffAdd      lipgloss.Style
	DiffRemove   lipgloss.Style
	DiffHeader   lipgloss.Style
	BadgePlain   lipgloss.Style
	BadgeActive  lipgloss.Style
	BadgeWarning lipgloss.Style
	BadgeMuted   lipgloss.Style
	Footer       lipgloss.Style
	GlanceTitle  lipgloss.Style
	GlanceBorder lipgloss.Style
}

var DefaultStyles = Styles{
	Faint:        lipgloss.NewStyle().Foreground(lipgloss.Color("8")),
	Dim:          lipgloss.NewStyle().Faint(true),
	Bold:         lipgloss.NewStyle().Bold(true),
	Prompt:       lipgloss.NewStyle().Foreground(lipgloss.Color("6")),
	PromptBright: lipgloss.NewStyle().Foreground(lipgloss.Color("14")),
	Error:        lipgloss.NewStyle().Foreground(lipgloss.Color("9")),
	Warning:      lipgloss.NewStyle().Foreground(lipgloss.Color("11")),
	ChatWarning:  lipgloss.NewStyle().Foreground(lipgloss.Color("3")),
	ChatSuccess:  lipgloss.NewStyle().Foreground(lipgloss.Color("2")),
	Success:      lipgloss.NewStyle().Foreground(lipgloss.Color("10")),
	Header:       lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("15")),
	Selected:     lipgloss.NewStyle().Reverse(true),
	Unselected:   lipgloss.NewStyle(),
	Detail:       lipgloss.NewStyle().Foreground(lipgloss.Color("245")),
	Thinking:     lipgloss.NewStyle().Foreground(lipgloss.Color("244")).Italic(true),
	ToolName:     lipgloss.NewStyle().Foreground(lipgloss.Color("12")).Bold(true),
	ToolDetail:   lipgloss.NewStyle().Foreground(lipgloss.Color("242")),
	DiffAdd:      lipgloss.NewStyle().Foreground(lipgloss.Color("10")),
	DiffRemove:   lipgloss.NewStyle().Foreground(lipgloss.Color("9")),
	DiffHeader:   lipgloss.NewStyle().Foreground(lipgloss.Color("14")).Bold(true),
	BadgePlain:   lipgloss.NewStyle().Foreground(lipgloss.Color("15")),
	BadgeActive:  lipgloss.NewStyle().Foreground(lipgloss.Color("10")).Bold(true),
	BadgeWarning: lipgloss.NewStyle().Foreground(lipgloss.Color("11")),
	BadgeMuted:   lipgloss.NewStyle().Foreground(lipgloss.Color("242")),
	Footer:       lipgloss.NewStyle().Foreground(lipgloss.Color("8")),
	GlanceTitle:  lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("13")),
	GlanceBorder: lipgloss.NewStyle().Foreground(lipgloss.Color("238")),
}
