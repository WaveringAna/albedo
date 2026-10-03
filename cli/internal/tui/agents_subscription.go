package tui

import (
	"context"
	"errors"

	"albedo/cli/internal/daemon"

	tea "charm.land/bubbletea/v2"
)

// Close stops the stream and invalidates batches, completions, and timers
// already queued for this view.
func (m *AgentsViewModel) Close() {
	m.viewGen++
	m.stopStream()
}

func (m *AgentsViewModel) stopStream() {
	if m.cancel != nil {
		m.cancel()
		m.cancel = nil
	}
	m.Gen++
	m.streamReady = false
	m.snapshotInFlight, m.snapshotDirty = false, false
}

func (m AgentsViewModel) snapshotCmd(gen int) tea.Cmd {
	conn, id := m.Conn, m.SessionID
	return func() tea.Msg {
		if conn == nil {
			return agentsSnapshotMsg{Gen: gen, Err: errors.New("daemon connection unavailable")}
		}
		tree, err := daemon.GetAgents(m.streamCtx, conn, id)
		return agentsSnapshotMsg{Gen: gen, Root: tree.Root, Nodes: tree.Nodes, Err: err}
	}
}

func (m *AgentsViewModel) startStream(gen int) tea.Cmd {
	if m.Conn == nil {
		return nil
	}
	if m.cancel != nil {
		m.cancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	m.cancel = cancel
	m.streamCtx = ctx
	m.streamReady = false
	m.snapshotInFlight, m.snapshotDirty = false, false
	events := make(chan tea.Msg, 1)
	m.events = events
	conn := m.Conn
	go func() {
		defer close(events)
		err := daemon.StreamAgents(ctx, conn, func(batch []daemon.AgentEvent) error {
			// Leaving the view stops its consumer. Cancellation must release a
			// producer blocked on a full queue so it can close the HTTP body.
			select {
			case events <- agentsEventsMsg{Gen: gen, Events: batch}:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		})
		select {
		case events <- agentsStreamClosedMsg{Gen: gen, Err: err}:
		case <-ctx.Done():
		}
	}()
	return waitAgents(events, gen)
}

func (m *AgentsViewModel) restartStream() tea.Cmd {
	m.stopStream()
	m.snapshotRevision++
	for _, n := range m.nodes {
		n.preview = agentTail{}
		n.tail = agentTail{}
		n.progressByCallID = nil
		n.progressOrder = nil
		n.previewCallID = ""
		n.lineKind = tailText
		n.seeded = false
		n.revision++
	}
	m.packets, m.floats = nil, nil
	m.ticking = false
	return m.startStream(m.Gen)
}

func waitAgents(events <-chan tea.Msg, gen int) tea.Cmd {
	return func() tea.Msg {
		batch, ok := <-events
		if !ok {
			return agentsStreamClosedMsg{Gen: gen}
		}
		return batch
	}
}

// seedCmd loads the selected agent's recent history once; failures retry.
func (m *AgentsViewModel) seedCmd() tea.Cmd {
	n := m.nodes[m.selected]
	if !m.streamReady || m.snapshotInFlight || m.err != nil || n == nil || n.seeded || n.id == agentsYou || m.Conn == nil {
		return nil
	}
	n.seeded = true
	conn, gen, id := m.Conn, m.Gen, n.id
	snapshot, ctx := m.snapshotRevision, m.streamCtx
	if ctx == nil {
		ctx = context.Background()
	}
	return func() tea.Msg {
		preview, err := daemon.GetSessionPreview(ctx, conn, id, 10)
		if err != nil {
			return agentsSeedErrMsg{Gen: gen, Snapshot: snapshot, ID: id, Err: err}
		}
		return agentsSeedMsg{Gen: gen, ID: id, Snapshot: snapshot, Items: preview.Items, Session: preview.Session}
	}
}
