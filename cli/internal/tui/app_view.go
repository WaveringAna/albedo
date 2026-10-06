package tui

import (
	"strings"

	tea "charm.land/bubbletea/v2"
)

// View captures the mouse only in chat, where it scrolls and selects; every
// other screen leaves it to the terminal.
func (m *AppModel) View() tea.View {
	v := tea.NewView(m.content())
	v.MouseMode = tea.MouseModeNone
	if m.State == AppStateChat {
		v.MouseMode = tea.MouseModeCellMotion
	}
	return v
}

func (m *AppModel) content() string {
	switch m.State {
	case AppStateChat:
		return m.Chat.View()
	case AppStateSessionPicker:
		var b strings.Builder
		for _, n := range m.Notices {
			style := DefaultStyles.Faint
			if n.Error {
				style = DefaultStyles.Error
			}
			b.WriteString(style.Render(n.Message))
			b.WriteByte('\n')
		}
		return b.String() + m.SessionPicker.View()
	case AppStateModelPicker:
		return m.ModelPicker.View()
	case AppStateExtensionPicker:
		return m.ExtensionPicker.View()
	case AppStateTreePicker:
		return m.TreePicker.View()
	case AppStateContextInspector:
		return m.ContextInspector.View()
	case AppStatePageView:
		return m.PageView.View()
	case AppStateCapabilityPage:
		return m.CapabilityPage.View()
	case AppStateWebhooksPage:
		return m.WebhooksPage.View()
	case AppStateAgents:
		return m.Agents.View()
	case AppStateFolderPicker:
		return m.FolderPicker.View()
	case AppStateLogin:
		return m.Login.View()
	default:
		return ""
	}
}
