package tui

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"albedo/cli/internal/daemon"

	tea "charm.land/bubbletea/v2"
)

// below counts the agents under id.
func (m AgentsViewModel) below(id string) int {
	count := 0
	for _, n := range m.nodes {
		for p := n.parent; p != ""; {
			if p == id {
				count++
				break
			}
			if m.nodes[p] == nil {
				break
			}
			p = m.nodes[p].parent
		}
	}
	return count
}

func (m AgentsViewModel) deleteCmd(id string) tea.Cmd {
	conn, gen, name := m.Conn, m.viewGen, m.label(id, "")
	condition := daemon.SessionCondition{}
	if n := m.nodes[id]; n != nil {
		condition = daemon.SessionCondition{ETag: n.session.ETag, FamilyRevision: n.session.FamilyRevision}
	}
	return func() tea.Msg {
		res, err := daemon.DeleteSession(context.Background(), conn, id, true, condition)
		if err != nil {
			return agentsSentMsg{Gen: gen, Action: "delete " + name, Err: err}
		}
		return agentsSentMsg{Gen: gen, Notice: name + ": " + res.Message}
	}
}

func (m *AgentsViewModel) sendCmd(id, text string) tea.Cmd {
	conn, gen, target := m.Conn, m.viewGen, m.label(id, "agent")
	handle, err := daemon.NewSubmission(id, daemon.SubmissionRequest{Content: &text})
	if err == nil {
		m.pendingOperations[handle.ID()] = agentPendingOperation{Handle: handle, Action: "send a message to " + target, Draft: text, InFlight: true}
	}
	return func() tea.Msg {
		result := agentsSentMsg{Gen: gen, Action: "send a message to " + target, Handle: handle, Draft: text, Err: err}
		if err == nil {
			_, result.Err = daemon.SubmitOperation(context.Background(), conn, handle)
		}
		return result
	}
}

func (m *AgentsViewModel) spawnCmd(parent, name, task string) tea.Cmd {
	conn, gen := m.Conn, m.viewGen
	draft := "/spawn " + name + " " + task
	if name == "" || task == "" {
		return func() tea.Msg {
			return agentsSentMsg{Gen: gen, Action: "start an agent", Draft: draft, Err: errors.New("use /spawn <name> <task>")}
		}
	}
	handle, err := daemon.NewCreation(daemon.CreateSessionRequest{Kind: "child", ParentID: parent, Address: name, Name: name, Task: task})
	if err == nil {
		m.pendingOperations[handle.ID()] = agentPendingOperation{Handle: handle, Action: "start " + name, Draft: draft, InFlight: true}
	}
	return func() tea.Msg {
		result := agentsSentMsg{Gen: gen, Action: "start " + name, Notice: "spawned " + name, Handle: handle, Draft: draft, Err: err}
		if err == nil {
			_, result.Err = daemon.CreateSessionOperation(context.Background(), conn, handle)
		}
		return result
	}
}

func agentOperationTick(id string, gen int) tea.Cmd {
	return tea.Tick(300*time.Millisecond, func(time.Time) tea.Msg { return agentsOperationPollMsg{ID: id, Gen: gen} })
}

func (m AgentsViewModel) resolveAgentOperation(pending agentPendingOperation) tea.Cmd {
	conn, gen := m.Conn, m.viewGen
	return func() tea.Msg {
		result := agentsSentMsg{Gen: gen, Action: pending.Action, Handle: pending.Handle, Draft: pending.Draft, Recovery: true, Notice: "Confirmed: " + pending.Action}
		if pending.Handle.IsCreation() {
			_, result.Err = daemon.ResolveCreation(context.Background(), conn, pending.Handle)
		} else {
			receipt, err := daemon.ResolveOperation(context.Background(), conn, pending.Handle)
			result.Err = err
			if err == nil {
				result.Err = receipt.Rejection()
				if receipt.Delivery != nil && *receipt.Delivery == "cancelled" {
					result.Notice = "The pending input was cancelled."
				}
			}
		}
		return result
	}
}

// askDelete asks before deleting an agent, and says what goes with it.
func (m *AgentsViewModel) askDelete(id string) {
	what := m.label(id, "")
	switch below := m.below(id); {
	case below == 1:
		what += " and the agent below it"
	case below > 1:
		what += fmt.Sprintf(" and the %d agents below it", below)
	}
	m.confirm.ask("delete", id, "delete", "Their transcripts and work will also be deleted. Delete "+what+"?")
}

func (m AgentsViewModel) key(msg tea.KeyPressMsg) (AgentsViewModel, tea.Cmd) {
	s, empty := msg.String(), m.input.Value() == ""
	if m.rename.active() {
		return m, m.rename.key(msg)
	}
	if m.confirm.asking() {
		id := m.confirm.target
		if m.confirm.key(msg) {
			m.confirm.dismiss()
			m.say("deleting " + m.label(id, "") + "…")
			return m, m.deleteCmd(id)
		}
		if !m.confirm.asking() {
			m.say("kept")
		}
		return m, nil
	}
	switch {
	case s == "ctrl+l":
		return m, m.restartStream()
	case s == "ctrl+r":
		if n := m.nodes[m.selected]; n != nil && n.id != agentsYou {
			m.rename.open(n.id, n.name, "name this agent")
			if n := m.nodes[m.rename.id]; n != nil {
				m.rename.etag = n.session.ETag
			}
		}
		return m, nil
	case s == "ctrl+x":
		switch n := m.nodes[m.selected]; {
		case n == nil || n.id == agentsYou:
		case n.id == m.SessionID:
			m.say("this is the session you opened the view from; delete it from the session browser")
		default:
			m.askDelete(n.id)
		}
		return m, nil
	case s == "esc" || s == "ctrl+c" || s == "ctrl+o":
		if !empty && s == "esc" {
			m.input.SetValue("")
			return m, nil
		}
		return m, func() tea.Msg { return AgentsDoneMsg{} }
	case s == "tab" || (empty && (s == "right" || s == "down")):
		m.cycle(1)
		return m, m.seedCmd()
	case s == "shift+tab" || (empty && (s == "left" || s == "up")):
		m.cycle(-1)
		return m, m.seedCmd()
	case s == "enter":
		n := m.nodes[m.selected]
		if n == nil {
			return m, nil
		}
		text := strings.TrimSpace(m.input.Value())
		if text == "" {
			if n.session.ID == "" {
				n.session = daemon.Session{ID: n.id, Title: n.name, Model: n.model}
			}
			sess := n.session
			return m, func() tea.Msg { return AgentsAttachMsg{Session: sess} }
		}
		m.input.SetValue("")
		if rest, ok := strings.CutPrefix(text, "/spawn "); ok {
			name, task, _ := strings.Cut(strings.TrimSpace(rest), " ")
			return m, m.spawnCmd(n.id, name, strings.TrimSpace(task))
		}
		return m, m.sendCmd(n.id, text)
	}
	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	return m, cmd
}

// renameBlank is what an agent is called once its given name is cleared.
func renameBlank(n *agentNode) string {
	return cmp.Or(n.address, "its latest message's title")
}

func (m *AgentsViewModel) say(text string) {
	m.notice = text
	m.noticeT = 3
}

func (m *AgentsViewModel) cycle(d int) {
	if n := len(m.order); n > 0 {
		i := max(0, slices.Index(m.order, m.selected))
		m.selected = m.order[(i+d+n)%n]
	}
}
