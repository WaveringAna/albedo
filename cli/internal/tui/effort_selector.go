package tui

import (
	"slices"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// Effort choices come from the active model, not the command catalog's examples.
func (m *ChatModel) openEffortSelector(levels []string) {
	m.effortOptions = slices.Clone(levels)
	m.effortSelected = max(0, slices.Index(levels, m.Effort))
	m.TextArea.Reset()
	m.syncLayout()
}

func (m ChatModel) effortSelectorView() string {
	if len(m.effortOptions) == 0 {
		return ""
	}
	width := m.chatWidth()
	selected := m.effortSelected
	// Keep the selected tier visible when the terminal cannot fit every tier.
	left, right := 0, len(m.effortOptions)
	label := func(i int) string {
		if i == selected {
			return " [" + m.effortOptions[i] + "] "
		}
		return m.effortOptions[i]
	}
	plain := func() string {
		parts := make([]string, 0, right-left)
		for i := left; i < right; i++ {
			parts = append(parts, label(i))
		}
		line := strings.Join(parts, " ─ ")
		if left > 0 {
			line = "‹ " + line
		}
		if right < len(m.effortOptions) {
			line += " ›"
		}
		return line
	}
	for ansi.StringWidth(plain()) > width && right-left > 1 {
		if selected-left > right-1-selected {
			left++
		} else {
			right--
		}
	}
	parts := make([]string, 0, right-left)
	for i := left; i < right; i++ {
		style := m.effortTierStyle(m.effortOptions[i])
		if i == selected {
			style = style.Inherit(DefaultStyles.Selected).Bold(true)
		}
		parts = append(parts, style.Render(label(i)))
	}
	decor := DefaultStyles.Decor.Render
	prefix, suffix := "", ""
	if left > 0 {
		prefix = decor("‹ ")
	}
	if right < len(m.effortOptions) {
		suffix = decor(" ›")
	}
	return ansi.Truncate(prefix+strings.Join(parts, decor(" ─ "))+suffix, width, "")
}

func (m ChatModel) effortTierStyle(level string) lipgloss.Style {
	switch level {
	case "low":
		return DefaultStyles.EffortLow
	case "medium":
		return DefaultStyles.EffortMedium
	case "high":
		return DefaultStyles.EffortHigh
	case "xhigh":
		return DefaultStyles.EffortXHigh
	case "max":
		return DefaultStyles.EffortMax
	default:
		return DefaultStyles.Muted
	}
}
