package tui

import (
	"strings"

	tea "charm.land/bubbletea/v2"
)

// markPrefix opens a private APC mark, which describes a row for selection and
// clicks rather than for the terminal. Ultraviolet preserves APC payloads, and
// Terminal.app prints unknown ones, so none may reach the screen.
const markPrefix = "\x1b_albedo:"

// stripPrivateMarks removes the marks from a frame. It scans for the prefix and
// copies only once it finds one. A mark's payload never contains an escape, so
// the first string terminator after it ends the mark, which is what the pattern
// `\x1b_albedo:[^\x1b]*\x1b\\` matched.
func stripPrivateMarks(s string) string {
	at := strings.Index(s, markPrefix)
	if at < 0 {
		return s
	}
	var b strings.Builder
	b.Grow(len(s))
	last := 0
	for at >= 0 {
		payload := s[at+len(markPrefix):]
		end := strings.Index(payload, "\x1b\\")
		if end < 0 || strings.IndexByte(payload[:end], '\x1b') >= 0 {
			// not a mark after all: keep the text and look past this prefix
			b.WriteString(s[last : at+len(markPrefix)])
			last = at + len(markPrefix)
		} else {
			b.WriteString(s[last:at])
			last = at + len(markPrefix) + end + 2
		}
		next := strings.Index(s[last:], markPrefix)
		if next < 0 {
			break
		}
		at = last + next
	}
	b.WriteString(s[last:])
	return b.String()
}

// View draws the active screen. The chat strips its own row marks as it builds
// a frame (and caches the result), so only other screens need the scan here.
func (m *AppModel) View() tea.View {
	content := m.content()
	if m.State != AppStateChat {
		content = stripPrivateMarks(content)
	}
	v := tea.NewView(content)
	v.MouseMode = tea.MouseModeNone
	// ReportFocus lets a client animate only while its terminal is focused.
	v.ReportFocus = true
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
	case AppStateDiscordPage:
		return m.DiscordPage.View()
	case AppStateConfigPage:
		return m.ConfigPage.View()
	case AppStateAgents:
		return m.Agents.View()
	case AppStateFolderPicker:
		return m.FolderPicker.View()
	case AppStateLogin:
		return m.Login.View()
	case AppStateQuota:
		return m.Quota.View()
	default:
		return ""
	}
}
