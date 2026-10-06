package tui

import (
	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
)

func (m *AppModel) handleChatLifecycle(msg tea.Msg) (tea.Cmd, bool) {
	// First: forward chat lifecycle messages even while a modal is open.
	var sid string
	var forward bool
	switch sm := msg.(type) {
	case ChatOlderLoadedMsg:
		sid, forward = sm.SessionID, true
	case ChatWindowMsg:
		sid, forward = sm.SessionID, true
	case ChatEditorFinishedMsg:
		sid, forward = sm.SessionID, true
	case ChatClearCopyStatusMsg:
		sid, forward = sm.SessionID, true
	case ChatStatusPollMsg:
		sid, forward = sm.SessionID, true
	case ChatCacheFadeMsg:
		sid, forward = sm.SessionID, true
	case ChatProgressTickMsg:
		// a tick dropped under a modal would leave the face frozen for good
		sid, forward = sm.SessionID, true
	case ChatLiveDrawMsg:
		sid, forward = sm.SessionID, true
	case ChatStatusMsg:
		sid, forward = sm.SessionID, true
	case ChatStreamResultMsg:
		sid, forward = sm.SessionID, true
	case ChatStreamClosedMsg:
		sid, forward = sm.SessionID, true
	case ChatInterruptMsg:
		sid, forward = sm.SessionID, true
	case ClipboardImagePastedMsg:
		sid, forward = sm.SessionID, true
	case ChatStreamEventMsg:
		sid, forward = sm.SessionID, true
		if m.ActiveSession != nil && sid == m.ActiveSession.ID && sm.Generation == m.Chat.Generation && sm.Event.Snapshot != nil {
			captured := *sm.Event.Snapshot
			m.ActiveSession = &captured
			m.SessionPicker.Renamed(captured)
		}
		if m.ActiveSession != nil && sid == m.ActiveSession.ID && sm.Generation == m.Chat.Generation && sm.Event.Type == daemon.EventUser && !sm.Event.Replayed {
			m.ClearNotices()
		}
	case ChatOperationPollMsg:
		sid, forward = sm.SessionID, true
	case ChatOperationResolvedMsg:
		sid, forward = sm.SessionID, true
	case ChatTurnSentMsg:
		sid, forward = sm.SessionID, true
		if m.ActiveSession != nil && sid == m.ActiveSession.ID && sm.Err == nil {
			m.ClearNotices()
		}
	}
	if forward {
		var cmd tea.Cmd
		if m.ActiveSession != nil && sid == m.ActiveSession.ID {
			m.Chat, cmd = m.Chat.Update(msg)
		}
		if event, ok := msg.(ChatStreamEventMsg); ok && event.SessionID == m.Chat.SessionID && event.Generation == m.Chat.Generation && event.Event.Type == daemon.EventReset {
			cmd = tea.Batch(cmd, m.loadSettingsCmd(m.SettingsGen))
		}
		if event, ok := msg.(ChatStreamEventMsg); ok && event.SessionID == m.Chat.SessionID && event.Generation == m.Chat.Generation && !event.Event.Replayed && event.Event.Invalidation != nil {
			if event.Event.Invalidation.Catalog {
				m.CatalogGen++
				cmd = tea.Batch(cmd, m.loadCommandCatalogCmd(m.CatalogGen))
			}
			if event.Event.Invalidation.Settings {
				m.SettingsGen++
				cmd = tea.Batch(cmd, m.loadSettingsCmd(m.SettingsGen))
			}
		}
		return cmd, true
	}

	return nil, false
}
