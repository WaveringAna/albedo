package tui

import (
	"cmp"
	"context"
	"errors"
	"strings"
	"time"

	"albedo/cli/internal/daemon"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
)

// The orchestrator view: every agent in the active session's tree as a dot,
// drawn in terminal cells. Running agents jam on their token rate, and mail
// travels the edges as a packet of blocks. The daemon's agents stream feeds
// it; the selected agent's tail sits beside it, and what you type goes to
// that agent as you.

type ChatOpenAgentsMsg struct{}
type AgentsDoneMsg struct{}

// AgentsAttachMsg opens the agent's session in the chat screen.
type AgentsAttachMsg struct{ Session daemon.Session }

type agentsSnapshotMsg struct {
	Err   error
	Root  string
	Nodes []daemon.AgentNode
	Gen   int
}

type agentsEventsMsg struct {
	Events []daemon.AgentEvent
	Gen    int
}

type agentsStreamClosedMsg struct {
	Gen int
	Err error
}
type agentsSnapshotRetryMsg struct{ Gen int }

// agentsSeedMsg is an agent's recent history, so its tail starts from where
// it is rather than empty.
type agentsSeedMsg struct {
	Snapshot int
	ID       string
	Items    []daemon.PreviewItem
	Session  *daemon.Session
	Gen      int
}
type agentsSeedErrMsg struct {
	Snapshot int
	Err      error
	ID       string
	Gen      int
}

type agentsFrameMsg struct{ Gen int }
type agentsSentMsg struct {
	Handle   *daemon.OperationHandle
	Draft    string
	Recovery bool
	Err      error
	Action   string
	Notice   string
	Gen      int
}
type agentsOperationPollMsg struct {
	ID  string
	Gen int
}
type agentPendingOperation struct {
	Handle        *daemon.OperationHandle
	Action, Draft string
	Expired       bool
	InFlight      bool
}
type agentsReconnectMsg struct{ Gen int }

type agentsGenMsg interface{ gen() int }

func (m agentsSnapshotRetryMsg) gen() int { return m.Gen }
func (m agentsSnapshotMsg) gen() int      { return m.Gen }
func (m agentsSeedMsg) gen() int          { return m.Gen }
func (m agentsSeedErrMsg) gen() int       { return m.Gen }
func (m agentsEventsMsg) gen() int        { return m.Gen }
func (m agentsStreamClosedMsg) gen() int  { return m.Gen }
func (m agentsReconnectMsg) gen() int     { return m.Gen }
func (m agentsFrameMsg) gen() int         { return m.Gen }

type agentMail struct {
	who      string
	kind     string
	incoming bool
}

type agentNode struct {
	session                        daemon.Session
	cursor                         *daemon.Cursor
	latestInput, latestAnswer      string
	currentRequest, latestProgress string
	id, parent, name, model        string
	address                        string // how its family mails it; a rename leaves it
	progressByCallID               map[string]*daemon.ToolProgress
	progressOrder                  []string
	previewCallID                  string
	mail                           []agentMail
	tail                           agentTail
	preview                        agentTail
	revision                       uint64
	hue                            rgb
	rate                           float64
	flash                          float64
	phase                          float64
	depth                          int
	chars                          int
	x, y                           int
	lineKind                       tailKind
	running, closed                bool
	peer                           bool // reached by mail, outside the tree
	seeded                         bool
}

// What a tail line is, which decides how it is drawn.
type tailKind byte

const (
	tailText     tailKind = iota // the agent's reply, as it streams
	tailThinking                 // reasoning, faint
	tailCode                     // a tool call's code as the model writes it
	tailOutput                   // what a tool printed
	tailMeta                     // ▸ tool, ← letter, » progress, ✕ error
)

type tailLine struct {
	text string
	kind tailKind
}

type AgentsViewModel struct {
	seenMail          []string
	pendingOperations map[string]agentPendingOperation
	bufferedActivity  map[string]daemon.AgentEvent
	last              time.Time
	err               error
	heat              map[string]float64
	events            chan tea.Msg
	streamCtx         context.Context
	streamReady       bool
	snapshotInFlight  bool
	snapshotDirty     bool
	snapshotRevision  int
	cancel            context.CancelFunc
	Conn              *daemon.Connection
	nodes             map[string]*agentNode
	SessionID         string
	root              string
	selected          string

	notice    string
	confirm   string // the agent waiting for y to delete it
	packets   []agentPacket
	floats    []agentFloat
	order     []string
	input     textinput.Model
	rename    renameField
	tailCache agentTailCache
	Width     int
	clock     float64
	Height    int
	Gen       int
	viewGen   int // User operation outcomes survive stream replacement.
	noticeT   float64
	ticking   bool // a frame tick is in flight
}

const (
	agentsYou     = "you"
	agentsFrame   = 70 * time.Millisecond
	agentsSlotW   = 16
	agentsLevelGp = 2
)

var agentsBars = []rune("▁▂▃▄▅▆▇█")

func NewAgentsViewModel(conn *daemon.Connection, sessionID string) AgentsViewModel {
	input := newField()
	input.CharLimit = 4000
	input.Focus()
	return AgentsViewModel{
		Conn:              conn,
		pendingOperations: map[string]agentPendingOperation{},
		SessionID:         sessionID,
		nodes:             map[string]*agentNode{},
		heat:              map[string]float64{},
		selected:          sessionID,
		input:             input,
		last:              time.Now(),
	}
}

func (m *AgentsViewModel) SetSize(w, h int) {
	m.Width = w
	m.Height = h
	m.layout()
	m.refreshTail()
}

func (m *AgentsViewModel) Init() tea.Cmd {
	m.viewGen++
	m.Gen++
	m.ticking = true
	cmds := []tea.Cmd{m.startStream(m.Gen), m.frameCmd(m.Gen), textinput.Blink}
	for id, pending := range m.pendingOperations {
		if !pending.Expired && !pending.InFlight {
			cmds = append(cmds, agentOperationTick(id, m.viewGen))
		}
	}
	return tea.Batch(cmds...)
}

func (m AgentsViewModel) frameCmd(gen int) tea.Cmd {
	return tea.Tick(agentsFrame, func(time.Time) tea.Msg { return agentsFrameMsg{Gen: gen} })
}

// Update handles msg, then starts the frame tick again if something began to
// move while it was stopped.
func (m AgentsViewModel) Update(msg tea.Msg) (AgentsViewModel, tea.Cmd) {
	m, cmd := m.update(msg)
	m.refreshTail()
	if m.ticking || !m.moving() {
		return m, cmd
	}
	m.ticking, m.last = true, time.Now()
	return m, tea.Batch(cmd, m.frameCmd(m.Gen))
}

func (m AgentsViewModel) update(msg tea.Msg) (AgentsViewModel, tea.Cmd) {
	if g, ok := msg.(agentsGenMsg); ok && g.gen() != m.Gen {
		return m, nil
	}
	switch msg := msg.(type) {
	case agentsSnapshotMsg:
		m.snapshotInFlight = false
		if msg.Err != nil {
			m.snapshotDirty = false
			m.err = msg.Err
			m.say("Could not refresh agents; retrying: " + msg.Err.Error())
			return m, tea.Tick(time.Second, func(time.Time) tea.Msg { return agentsSnapshotRetryMsg{Gen: m.Gen} })
		}
		if m.snapshotDirty {
			m.snapshotDirty = false
			m.snapshotInFlight = true
			return m, m.snapshotCmd(m.Gen)
		}
		m.err, m.root = nil, msg.Root
		m.snapshotRevision++
		previous := m.nodes
		m.nodes = make(map[string]*agentNode, len(msg.Nodes))
		for _, wire := range msg.Nodes {
			if n := previous[wire.Session.ID]; n != nil {
				m.nodes[wire.Session.ID] = n
			}
			n := m.node(wire.Session.ID, wire.Name)
			n.name = wire.Name
			n.parent, n.address = "", ""
			n.seeded = false
			n.session = wire.Session
			n.cursor = nil
			m.apply(daemon.AgentEvent{Type: "activity", Session: wire.Session.ID, Cursor: wire.Cursor, Activity: &wire.Activity, CurrentProgress: wire.CurrentProgress, Running: wire.Running})
			n.model = wire.Session.Model
			n.depth = wire.Depth
			n.running = wire.Running
			n.closed = wire.Closed
			n.peer = false
			if wire.Address != nil {
				n.address = *wire.Address
			}
			if wire.Parent != nil {
				n.parent = *wire.Parent
			}
		}
		if m.nodes[m.selected] == nil {
			m.selected = m.root
		}
		if m.nodes[m.confirm] == nil {
			m.confirm = ""
		}
		if m.nodes[m.rename.id] == nil {
			m.rename = renameField{}
		}
		for _, event := range m.bufferedActivity {
			m.apply(event)
		}
		m.bufferedActivity = nil
		m.layout()
		return m, m.seedCmd()

	case agentsSeedMsg:
		if msg.Snapshot != m.snapshotRevision {
			return m, nil
		}
		n := m.nodes[msg.ID]
		if n == nil {
			return m, nil
		}
		var seeded agentTail
		for _, item := range msg.Items {
			switch item.Type {
			case "user", "tool":
				prefix := "← "
				if item.Type == "tool" {
					prefix = "▸ "
				}
				seeded.push(tailLine{kind: tailMeta, text: prefix + firstLine(item.Preview)})
			default:
				for line := range strings.SplitSeq(item.Preview, "\n") {
					seeded.push(tailLine{kind: tailText, text: line})
				}
			}
		}
		if msg.Session == nil || msg.Session.Cursor == nil || n.cursor == nil || msg.Session.Cursor.Generation == n.cursor.Generation && msg.Session.Cursor.Sequence >= n.cursor.Sequence {
			n.tail = seeded
			if msg.Session != nil {
				n.session = *msg.Session
				n.cursor = msg.Session.Cursor
			}
		}
		n.revision++
		return m, nil

	case agentsSeedErrMsg:
		if msg.Snapshot != m.snapshotRevision {
			return m, nil
		}
		// The seed died; unseed its node so the next selection tries again.
		if n := m.nodes[msg.ID]; n != nil {
			n.seeded = false
			m.say("Could not load recent messages for " + m.label(msg.ID, "this agent") + ". Select it again to retry: " + msg.Err.Error())
		}
		return m, nil

	case agentsEventsMsg:
		if len(msg.Events) == 1 && msg.Events[0].Type == "overflow" {
			return m, m.restartStream()
		}
		var snapshot tea.Cmd
		if !m.streamReady {
			m.streamReady = true
			m.snapshotInFlight = true
			snapshot = m.snapshotCmd(m.Gen)
		}
		relayout := false
		for _, event := range msg.Events {
			if m.snapshotInFlight {
				switch event.Type {
				case "invalidate", "spawn", "gone", "running", "renamed", "closed":
					m.snapshotDirty = true
				}
			}
			if event.Type == "activity" && m.snapshotInFlight {
				if m.bufferedActivity == nil {
					m.bufferedActivity = map[string]daemon.AgentEvent{}
				}
				m.bufferedActivity[event.Session] = event
			}
			if event.Type == "invalidate" && !m.snapshotInFlight {
				m.snapshotInFlight = true
				snapshot = m.snapshotCmd(m.Gen)
			}
			relayout = m.apply(event) || relayout
		}
		if relayout {
			m.layout()
		}
		return m, tea.Batch(snapshot, waitAgents(m.events, m.Gen))

	case agentsStreamClosedMsg:
		if msg.Err != nil {
			m.err = msg.Err
			m.say("Agent stream failed; ctrl+l retries: " + msg.Err.Error())
			if failure, ok := errors.AsType[*daemon.StreamError](msg.Err); ok && failure.Kind != daemon.StreamTransient {
				m.stopStream()
				m.ticking = false
				return m, nil
			}
		}
		return m, tea.Tick(time.Second, func(time.Time) tea.Msg { return agentsReconnectMsg{Gen: m.Gen} })

	case agentsReconnectMsg:
		return m, m.restartStream()

	case agentsSnapshotRetryMsg:
		if !m.streamReady || m.snapshotInFlight {
			return m, nil
		}
		m.snapshotInFlight = true
		return m, m.snapshotCmd(m.Gen)

	case agentsFrameMsg:
		m.step()
		if m.ticking = m.moving(); !m.ticking {
			return m, nil
		}
		return m, m.frameCmd(m.Gen)

	case agentsOperationPollMsg:
		pending, ok := m.pendingOperations[msg.ID]
		if !ok || pending.Expired || msg.Gen != m.viewGen {
			return m, nil
		}
		return m, m.resolveAgentOperation(pending)
	case agentsSentMsg:
		if msg.Gen != m.viewGen {
			if msg.Handle == nil {
				return m, nil
			}
			if _, retained := m.pendingOperations[msg.Handle.ID()]; !retained {
				return m, nil
			}
		}
		if msg.Err != nil {
			_, uncertain := errors.AsType[*daemon.UncertainOutcomeError](msg.Err)
			if msg.Handle != nil && (uncertain || msg.Recovery) {
				if m.pendingOperations == nil {
					m.pendingOperations = map[string]agentPendingOperation{}
				}
				pending := agentPendingOperation{Handle: msg.Handle, Action: msg.Action, Draft: msg.Draft, Expired: daemon.IsOperationExpired(msg.Err)}
				if api, ok := errors.AsType[*daemon.APIError](msg.Err); ok && api.StatusCode >= 400 && api.StatusCode < 500 && api.StatusCode != 404 && !pending.Expired && !uncertain {
					delete(m.pendingOperations, msg.Handle.ID())
					if m.input.Value() == "" {
						m.input.SetValue(msg.Draft)
					}
					m.say(msg.Err.Error())
					return m, nil
				}
				m.pendingOperations[msg.Handle.ID()] = pending
				m.say(operationError(msg.Err, "Could not "+msg.Action+": ", "The outcome for "+msg.Handle.ID()+" remains unresolved."))
				if pending.Expired {
					return m, nil
				}
				return m, agentOperationTick(msg.Handle.ID(), m.viewGen)
			}
			if msg.Draft != "" && m.input.Value() == "" {
				m.input.SetValue(msg.Draft)
			}
			if msg.Handle != nil {
				delete(m.pendingOperations, msg.Handle.ID())
			}
			m.say(operationError(msg.Err, "Could not "+msg.Action+": ", "The request may have been accepted; refresh before trying again."))
		} else {
			if msg.Handle != nil {
				delete(m.pendingOperations, msg.Handle.ID())
			}
			if msg.Notice != "" {
				m.say(msg.Notice)
			}
		}
		return m, nil

	case sessionRenamedMsg:
		switch {
		case msg.Err != nil:
			m.say(operationError(msg.Err, "Could not rename the session. Try again: ", "Session may have been renamed; refresh before trying again."))
		case msg.Name == "":
			m.say("name cleared")
		default:
			m.say("renamed to " + msg.Name)
		}
		return m, nil

	case tea.KeyPressMsg:
		return m.key(msg)
	}
	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	return m, cmd
}

func (m *AgentsViewModel) label(id, fallback string) string {
	if id == agentsYou {
		return agentsYou
	}
	if n := m.nodes[id]; n != nil {
		return n.name
	}
	return cmp.Or(fallback, shortID(id))
}

// ─── layout ───

// ─── drawing ───
