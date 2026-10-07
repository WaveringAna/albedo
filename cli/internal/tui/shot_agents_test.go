package tui

import (
	"albedo/cli/internal/daemon"

	tea "charm.land/bubbletea/v2"
)

// agentsShotModel is agentsFixture's tree without a *testing.T, for the gallery.
func agentsShotModel(width, height int) AgentsViewModel {
	m := NewAgentsViewModel(nil, "lead")
	m.Gen = 1
	m.streamReady = true
	m.SetSize(width, height)
	lead, coder := "lead", "coder"
	m, _ = m.Update(agentsSnapshotMsg{Gen: 1, Root: "lead", Nodes: []daemon.AgentNode{
		{Session: daemon.Session{ID: "lead", Title: "lead", Model: "gpt-6-luna"}, Name: "lead", Running: true},
		{Session: daemon.Session{ID: "scout", Model: "gpt-6-luna"}, Parent: &lead, Name: "scout", Depth: 1},
		{Session: daemon.Session{ID: "coder", Model: "gpt-6-luna"}, Parent: &lead, Name: "coder", Depth: 1, Running: true},
		{Session: daemon.Session{ID: "tests", Model: "gpt-6-luna"}, Parent: &coder, Name: "tests", Depth: 2},
	}})
	return m
}

// agentsDeleteShot opens the delete question on an agent, then presses keys.
func agentsDeleteShot(id string, keys ...tea.KeyPressMsg) func(width, height int) string {
	return func(width, height int) string {
		m := agentsShotModel(width, height)
		m.selected = id
		m, _ = m.key(tea.KeyPressMsg{Code: 'x', Mod: tea.ModCtrl})
		for _, key := range keys {
			m, _ = m.key(key)
		}
		return m.View()
	}
}

func init() {
	registerShots("agents",
		shotState{"delete-confirm", agentsDeleteShot("coder")},
		shotState{"delete-leaf-confirm", agentsDeleteShot("scout")},
		shotState{"delete-kept", agentsDeleteShot("coder", tea.KeyPressMsg{Code: tea.KeyEscape})},
	)
}
