package tui

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// Effort choices come from the active model, not the command catalog's examples.
func (m *ChatModel) openEffortSelector(levels []string) {
	m.effortOptions = append([]string(nil), levels...)
	m.effortSelected = 0
	for i, level := range levels {
		if level == m.Effort {
			m.effortSelected = i
			break
		}
	}
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
		prefix, suffix := "", ""
		if left > 0 {
			prefix += "‹ "
		}
		if right < len(m.effortOptions) {
			suffix = " ›"
		}
		return prefix + strings.Join(parts, " ─ ") + suffix
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
			style = style.Inherit(m.Styles.Selected).Bold(true)
		}
		parts = append(parts, style.Render(label(i)))
	}
	prefix := ""
	if left > 0 {
		prefix += m.Styles.Decor.Render("‹ ")
	}
	suffix := ""
	if right < len(m.effortOptions) {
		suffix = m.Styles.Decor.Render(" ›")
	}
	return ansi.Truncate(prefix+strings.Join(parts, m.Styles.Decor.Render(" ─ "))+suffix, width, "")
}

func (m ChatModel) effortTierStyle(level string) lipgloss.Style {
	switch level {
	case "low":
		return m.Styles.EffortLow
	case "medium":
		return m.Styles.EffortMedium
	case "high":
		return m.Styles.EffortHigh
	case "xhigh":
		return m.Styles.EffortXHigh
	case "max":
		return m.Styles.EffortMax
	default:
		return m.Styles.Muted
	}
}
