package tui

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"hash/fnv"
	"math"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"albedo/cli/internal/daemon"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
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
	Nodes []agentWire
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
	Items    []struct {
		Type    string `json:"type"`
		Preview string `json:"preview"`
	}
	Gen int
}
type agentsSeedErrMsg struct {
	Snapshot int
	Err      error
	ID       string
	Gen      int
}

type agentsFrameMsg struct{ Gen int }
type agentsSentMsg struct {
	Err    error
	Action string
	Notice string
	Gen    int
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

type agentWire struct {
	Parent  *string        `json:"parent"`
	Address *string        `json:"address"`
	Session daemon.Session `json:"session"`
	Name    string         `json:"name"`
	Depth   int            `json:"depth"`
	Running bool           `json:"running"`
	Closed  bool           `json:"closed"`
}

type agentMail struct {
	who      string
	kind     string
	incoming bool
}

type agentNode struct {
	session                 daemon.Session
	id, parent, name, model string
	address                 string // how its family mails it; a rename leaves it
	call                    string // the tool call whose arguments are streaming
	mail                    []agentMail
	tail                    agentTail
	preview                 agentPreview
	revision                uint64
	hue                     rgb
	rate                    float64
	flash                   float64
	phase                   float64
	depth                   int
	chars                   int
	x, y                    int
	lineKind                tailKind
	running, closed         bool
	peer                    bool // reached by mail, outside the tree
	seeded                  bool
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

type agentPacket struct {
	to     string
	edge   string
	path   [][2]int
	hue    rgb
	pos    float64
	blocks int
	tokens int
}

type agentFloat struct {
	text string
	hue  rgb
	x, y int
	t    float64
}

type AgentsViewModel struct {
	last             time.Time
	err              error
	heat             map[string]float64
	events           chan tea.Msg
	streamCtx        context.Context
	streamReady      bool
	snapshotInFlight bool
	snapshotDirty    bool
	snapshotRevision int
	cancel           context.CancelFunc
	Conn             *daemon.Connection
	nodes            map[string]*agentNode
	SessionID        string
	root             string
	selected         string

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
		Conn:      conn,
		SessionID: sessionID,
		nodes:     map[string]*agentNode{},
		heat:      map[string]float64{},
		selected:  sessionID,
		input:     input,
		last:      time.Now(),
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
	return tea.Batch(m.startStream(m.Gen), m.frameCmd(m.Gen), textinput.Blink)
}

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
		tree, err := daemon.RequestOperation[struct {
			Root  string      `json:"root"`
			Nodes []agentWire `json:"nodes"`
		}](m.streamCtx, conn, daemon.Operation{Name: "snapshot", Method: http.MethodGet, Path: "/agents?session=" + url.QueryEscape(id), Body: nil, Policy: daemon.ReadRecovery})
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
		n.preview = agentPreview{}
		n.tail = agentTail{}
		n.call = ""
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
		existing := slices.Collect(n.tail.newest(false))
		for _, line := range slices.Backward(existing) {
			seeded.push(line)
		}
		seeded.omitted = seeded.omitted || n.tail.omitted
		n.tail = seeded
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
				case "spawn", "gone", "running", "renamed", "closed":
					m.snapshotDirty = true
				}
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

	case agentsSentMsg:
		if msg.Gen != m.viewGen {
			return m, nil
		}
		if msg.Err != nil {
			m.say(operationError(msg.Err, "Could not "+msg.Action+": ", "The request to "+msg.Action+" may have been accepted; check the agent before trying again."))
		} else if msg.Notice != "" {
			m.say(msg.Notice)
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

func (m AgentsViewModel) key(msg tea.KeyPressMsg) (AgentsViewModel, tea.Cmd) {
	s, empty := msg.String(), m.input.Value() == ""
	if m.rename.active() {
		return m, m.rename.key(msg)
	}
	if m.confirm != "" {
		id := m.confirm
		m.confirm = ""
		if s == "y" {
			m.say("deleting " + m.label(id, "") + "…")
			return m, m.deleteCmd(id)
		}
		m.say("kept")
		return m, nil
	}
	switch {
	case s == "ctrl+l":
		return m, m.restartStream()
	case s == "ctrl+r":
		if n := m.nodes[m.selected]; n != nil && n.id != agentsYou {
			m.rename.open(n.id, n.name, "name this agent")
		}
		return m, nil
	case s == "ctrl+x":
		switch n := m.nodes[m.selected]; {
		case n == nil || n.id == agentsYou:
		case n.id == m.SessionID:
			m.say("this is the session you opened the view from; delete it from the session browser")
		default:
			m.confirm = n.id
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
		path := fmt.Sprintf("/sessions/%s/preview?limit=10", url.PathEscape(id))
		res, err := daemon.RequestOperation[agentsSeedMsg](ctx, conn, daemon.Operation{Name: "seed", Method: http.MethodGet, Path: path, Body: nil, Policy: daemon.ReadRecovery})
		if err != nil {
			return agentsSeedErrMsg{Gen: gen, Snapshot: snapshot, ID: id, Err: err}
		}
		res.Gen, res.ID, res.Snapshot = gen, id, snapshot
		return res
	}
}

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
	return func() tea.Msg {
		res, err := daemon.DeleteSession(context.Background(), conn, id, true)
		if err != nil {
			return agentsSentMsg{Gen: gen, Action: "delete " + name, Err: err}
		}
		return agentsSentMsg{Gen: gen, Notice: fmt.Sprintf("deleted %s (%d sessions)", name, res.Deleted)}
	}
}

func (m AgentsViewModel) sendCmd(id, text string) tea.Cmd {
	conn, gen, target := m.Conn, m.viewGen, m.label(id, "agent")
	return func() tea.Msg {
		_, err := daemon.Submit(context.Background(), conn, id, map[string]any{"content": text})
		return agentsSentMsg{Gen: gen, Action: "send a message to " + target, Err: err}
	}
}

func (m AgentsViewModel) spawnCmd(parent, name, task string) tea.Cmd {
	conn, gen := m.Conn, m.viewGen
	return func() tea.Msg {
		if name == "" || task == "" {
			return agentsSentMsg{Gen: gen, Action: "start an agent", Err: errors.New("use /spawn <name> <task>")}
		}
		_, err := daemon.CreateChild(context.Background(), conn, parent, map[string]any{"name": name, "task": task})
		if err != nil {
			return agentsSentMsg{Gen: gen, Action: "start " + name, Err: err}
		}
		return agentsSentMsg{Gen: gen, Notice: "spawned " + name}
	}
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

// node finds or makes the dot for a session.
func (m *AgentsViewModel) node(id, name string) *agentNode {
	if n, ok := m.nodes[id]; ok {
		if name != "" {
			n.name = name
		}
		return n
	}
	if name == "" {
		name = shortID(id)
	}
	n := &agentNode{id: id, name: name, hue: hueFor(id), phase: float64(hashOf(id)%628) / 100}
	m.nodes[id] = n
	return n
}

func shortID(id string) string {
	return id[:min(len(id), 8)]
}

func hashOf(s string) uint32 {
	h := fnv.New32a()
	_, _ = h.Write([]byte(s))
	return h.Sum32()
}

func hueFor(id string) rgb {
	hues := agentColors().hues
	return hues[hashOf(id)%uint32(len(hues))]
}

// apply folds one bus event into the view; true when the tree changed shape.
func (m *AgentsViewModel) apply(event daemon.AgentEvent) bool {
	kind := event.Type
	id := event.Session
	switch kind {
	case "spawn":
		parent := event.Parent
		if _, ok := m.nodes[parent]; !ok {
			return false
		}
		n := m.node(id, event.Name)
		n.parent, n.model, n.depth = parent, event.Model, event.Depth
		n.peer, n.flash = false, 1
		return true
	case "gone":
		if _, ok := m.nodes[id]; !ok {
			return false
		}
		delete(m.nodes, id)
		if m.rename.id == id {
			m.rename = renameField{}
		}
		if m.confirm == id {
			m.confirm = ""
		}
		if m.selected == id {
			m.selected = m.root
		}
		return true
	case "mail":
		from, to := event.From, event.To
		fromName := event.FromName
		changed := false
		ensure := func(nodeID, name string) {
			if _, ok := m.nodes[nodeID]; !ok {
				m.node(nodeID, name).peer = true
				changed = true
			}
		}
		ensure(to, "")
		source := agentsYou
		if from != "" {
			ensure(from, fromName)
			source = from
		}
		if changed {
			m.layout()
		}
		bytes, label := event.Bytes, event.Kind
		addMail := func(nodeID string, incoming bool, who string) {
			if n := m.nodes[nodeID]; n != nil {
				n.mail = capped(append(n.mail, agentMail{incoming: incoming, who: who, kind: label}), 12)
			}
		}
		addMail(to, true, m.label(source, fromName))
		addMail(source, false, m.label(to, ""))
		m.send(source, to, max(1, bytes/4))
		return false
	}
	n, ok := m.nodes[id]
	if !ok {
		return false
	}
	switch kind {
	case "running":
		n.running = event.Running
		if !n.running {
			m.flushLine(n)
		}
	case "text", "thinking":
		text := event.Text
		n.chars += utf8.RuneCountInString(text)
		n.rate += float64(len(text))
		tail := tailText
		if kind == "thinking" {
			tail = tailThinking
		}
		m.stream(n, tail, text)
	case "arguments_delta":
		text := event.Text
		n.chars += utf8.RuneCountInString(text)
		n.rate += float64(len(text))
		if call := event.CallID; call != n.call || n.lineKind != tailCode {
			m.flushLine(n)
			n.call = call
		}
		n.lineKind = tailCode
		if n.preview.appendArguments(text) {
			n.revision++
		}
	case "tool_progress":
		progress := event.Progress
		if progress != nil && progress.Phase == "running" {
			m.flushLine(n)
			m.pushTail(n, tailMeta, "▸ "+progress.Name)
		}
	case "tool":
		m.flushLine(n)
		for line := range strings.SplitSeq(event.Output, "\n") {
			if strings.TrimSpace(line) != "" {
				m.pushTail(n, tailOutput, line)
			}
		}
	case "user":
		text := event.Text
		m.flushLine(n)
		m.pushTail(n, tailMeta, "← "+firstLine(text))
		// Mail already travelled as a packet; a person typing is new.
		if event.Source == "chat" {
			m.send(agentsYou, id, max(1, len(text)/4))
		}
	case "message":
		// A root's answer goes back to you.
		if n.parent == "" && !n.peer {
			m.send(id, agentsYou, max(1, len(event.Text)/4))
		}
	case "error":
		m.pushTail(n, tailMeta, "✕ "+event.Text)
	case "interrupted":
		m.flushLine(n)
		m.pushTail(n, tailMeta, "· interrupted")
	case "progress":
		m.flushLine(n)
		m.pushTail(n, tailMeta, "» "+event.Text)
		n.flash = 0.6
	case "renamed":
		n.name = event.Name
	case "closed":
		n.closed, n.running = true, false
	}
	return false
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

// capped keeps only the newest keep entries of a growing slice.
func capped[S ~[]E, E any](list S, keep int) S {
	if len(list) > keep {
		return list[len(list)-keep:]
	}
	return list
}

// stream appends streamed text of one kind, closing a line at each newline.
func (m *AgentsViewModel) stream(n *agentNode, kind tailKind, text string) {
	if n.lineKind != kind {
		m.flushLine(n)
		n.lineKind = kind
	}
	for {
		head, rest, found := strings.Cut(text, "\n")
		n.preview.lines.write(head, kind)
		n.revision++
		if !found {
			return
		}
		m.flushLine(n)
		n.lineKind = kind
		text = rest
	}
}

// flushLine settles whatever is streaming into the tail: a partial line, or
// the code of a finished tool call.
func (m *AgentsViewModel) flushLine(n *agentNode) {
	if n.lineKind == tailCode {
		n.preview.finish()
		lines := slices.Collect(n.preview.lines.newest(true))
		for _, line := range slices.Backward(lines) {
			m.pushTail(n, tailCode, line.text)
		}
	} else {
		for line := range n.preview.lines.newest(false) {
			if strings.TrimSpace(line.text) != "" {
				m.pushTail(n, n.lineKind, line.text)
			}
		}
	}
	n.tail.omitted = n.tail.omitted || n.preview.lines.omitted
	n.preview = agentPreview{}
	n.call = ""
	n.lineKind = tailText
	n.revision++
}

func (m *AgentsViewModel) pushTail(n *agentNode, kind tailKind, line string) {
	n.tail.push(tailLine{kind: kind, text: line})
	n.revision++
}

// ─── layout ───

func (m *AgentsViewModel) dagWidth() int {
	w := m.paneWidth()
	if w > 0 {
		return m.Width - w - 1
	}
	return m.Width
}

func (m *AgentsViewModel) paneWidth() int {
	if m.Width < 96 {
		return 0
	}
	return min(46, max(34, m.Width/3))
}

// layout places dots by depth, each depth wrapped into rows that fit the
// pane, parents before their children so a family stays together.
func (m *AgentsViewModel) layout() {
	// The app sizes every screen, including this one before it first opens.
	if m.nodes == nil {
		return
	}
	you := m.node(agentsYou, agentsYou)
	you.x, you.y = 2, 2
	children := map[string][]string{}
	var roots, peers []string
	for id, n := range m.nodes {
		switch {
		case id == agentsYou:
		case n.peer:
			peers = append(peers, id)
		case n.parent == "" || m.nodes[n.parent] == nil:
			roots = append(roots, id)
		default:
			children[n.parent] = append(children[n.parent], id)
		}
	}
	for _, list := range children {
		slices.Sort(list)
	}
	slices.Sort(roots)
	slices.Sort(peers)
	levels := [][]string{append(roots, peers...)}
	for {
		var next []string
		for _, id := range levels[len(levels)-1] {
			next = append(next, children[id]...)
		}
		if len(next) == 0 {
			break
		}
		levels = append(levels, next)
	}
	width := max(agentsSlotW, m.dagWidth()-4)
	perRow := max(1, width/agentsSlotW)
	y := 5
	m.order = m.order[:0]
	for _, level := range levels {
		for start := 0; start < len(level); start += perRow {
			row := level[start:min(len(level), start+perRow)]
			used := len(row) * agentsSlotW
			x := 2 + max(0, (width-used)/2)
			for i, id := range row {
				n := m.nodes[id]
				n.x, n.y = x+i*agentsSlotW, y
				m.order = append(m.order, id)
			}
			y += 3
		}
		y += agentsLevelGp
	}
	if m.nodes[m.selected] == nil && len(m.order) > 0 {
		m.selected = m.order[0]
	}
}

// route runs from a to b: down from a, across the row above b, into b. A
// route upward is the same route reversed.
func route(a, b *agentNode) [][2]int {
	if b.y < a.y {
		cells := route(b, a)
		slices.Reverse(cells)
		return cells
	}
	var cells [][2]int
	channel := b.y - 1
	if b.y == a.y {
		channel = a.y - 1
		cells = append(cells, [2]int{a.x, a.y - 1})
	}
	for r := a.y + 1; r <= channel; r++ {
		cells = append(cells, [2]int{a.x, r})
	}
	step := 1
	if b.x < a.x {
		step = -1
	}
	for c := a.x + step; c != b.x+step; c += step {
		cells = append(cells, [2]int{c, channel})
	}
	return cells
}

func edgeKey(a, b string) string { return a + ">" + b }

func (m *AgentsViewModel) send(from, to string, tokens int) {
	a, b := m.nodes[from], m.nodes[to]
	if a == nil || b == nil || from == to {
		return
	}
	path := route(a, b)
	if len(path) == 0 {
		return
	}
	blocks := max(1, min(5, int(math.Round(math.Log2(float64(tokens)/200+1)))))
	var key string
	if a.parent == to {
		key = edgeKey(to, from)
	} else {
		key = edgeKey(from, to)
	}
	m.packets = append(m.packets, agentPacket{path: path, pos: -float64(blocks), blocks: blocks, hue: a.hue, to: to, tokens: tokens, edge: key})
	m.heat[key] = 1
}

// step advances one frame of animation.
func (m *AgentsViewModel) step() {
	now := time.Now()
	dt := math.Min(0.2, now.Sub(m.last).Seconds())
	m.last = now
	m.clock += dt
	m.noticeT = math.Max(0, m.noticeT-dt)
	live := m.packets[:0]
	for _, p := range m.packets {
		p.pos += 30 * dt
		m.heat[p.edge] = 1
		if p.pos-float64(p.blocks) >= float64(len(p.path)-1) {
			if n := m.nodes[p.to]; n != nil {
				n.flash = 1
				m.floats = append(m.floats, agentFloat{x: n.x + 2, y: n.y - 1, text: "▴" + compactCount(p.tokens), hue: p.hue})
			}
			continue
		}
		live = append(live, p)
	}
	m.packets = live
	for key, h := range m.heat {
		if slices.ContainsFunc(m.packets, func(p agentPacket) bool { return p.edge == key }) {
			continue
		}
		h -= dt * 0.8
		if h <= 0 {
			delete(m.heat, key)
			continue
		}
		m.heat[key] = h
	}
	floats := m.floats[:0]
	for _, f := range m.floats {
		f.t += dt
		if f.t < 1.4 {
			floats = append(floats, f)
		}
	}
	m.floats = floats
	for _, n := range m.nodes {
		n.flash = math.Max(0, n.flash-dt*2.5)
		n.rate *= math.Exp(-dt * 1.5)
	}
}

// moving is whether the next frame can differ from this one: running agents
// pulse, and packets, heat, floats, flashes, and notices play out.
func (m AgentsViewModel) moving() bool {
	if len(m.packets) > 0 || len(m.heat) > 0 || len(m.floats) > 0 || m.noticeT > 0 {
		return true
	}
	for _, n := range m.nodes {
		if n.running || n.flash > 0 {
			return true
		}
	}
	return false
}

func compactCount(n int) string {
	if n >= 1000 {
		return fmt.Sprintf("%.1fk", float64(n)/1000)
	}
	return fmt.Sprintf("%d", n)
}

// ─── drawing ───

type agentCell struct {
	hue *rgb
	r   rune
}

type agentCanvas struct {
	cells [][]agentCell
	w, h  int
}

func newCanvas(w, h int) *agentCanvas {
	c := &agentCanvas{w: w, h: h, cells: make([][]agentCell, h)}
	for y := range c.cells {
		c.cells[y] = make([]agentCell, w)
		for x := range c.cells[y] {
			c.cells[y][x] = agentCell{r: ' '}
		}
	}
	return c
}

func (c *agentCanvas) put(x, y int, s string, hue rgb) {
	h := hue
	for _, r := range s {
		if x >= 0 && x < c.w && y >= 0 && y < c.h {
			c.cells[y][x] = agentCell{r: r, hue: &h}
		}
		x++
	}
}

var sgrCache = map[string]string{}

// sgrCached memoizes the escape sequence for one hex color.
func sgrCached(hex string) string {
	seq, ok := sgrCache[hex]
	if !ok {
		seq = sgr(hex, "")
		sgrCache[hex] = seq
	}
	return seq
}

func (c *agentCanvas) line(y int) string {
	var b strings.Builder
	current := ""
	for _, cell := range c.cells[y] {
		seq := ""
		if cell.hue != nil && cell.r != ' ' {
			seq = sgrCached(cell.hue.hex())
		}
		if seq != current {
			if current != "" {
				b.WriteString(ansiReset)
			}
			b.WriteString(seq)
			current = seq
		}
		b.WriteRune(cell.r)
	}
	if current != "" {
		b.WriteString(ansiReset)
	}
	return b.String()
}

var agentGlyphs = map[int]rune{5: '│', 10: '─', 6: '╭', 12: '╮', 3: '╰', 9: '╯', 7: '├', 13: '┤', 14: '┬', 11: '┴', 15: '┼', 1: '│', 4: '│', 2: '─', 8: '─'}

func (m *AgentsViewModel) drawEdges(c *agentCanvas) {
	type mark struct {
		mask   int
		heat   float64
		hue    rgb
		dotted bool
	}
	marks := map[[2]int]*mark{}
	// dir is one bit per compass direction; a cell's mask names the arms meeting in it.
	dir := func(dx, dy int) int {
		switch {
		case dy < 0:
			return 1
		case dy > 0:
			return 4
		case dx > 0:
			return 2
		default:
			return 8
		}
	}
	draw := func(from, to *agentNode, heat float64, dotted bool) {
		cells := append([][2]int{{from.x, from.y}}, route(from, to)...)
		for i := 1; i < len(cells); i++ {
			cell, prev := cells[i], cells[i-1]
			mk := marks[cell]
			if mk == nil {
				mk = &mark{hue: from.hue}
				marks[cell] = mk
			}
			next := [2]int{to.x, to.y}
			if i+1 < len(cells) {
				next = cells[i+1]
			}
			mk.mask |= dir(prev[0]-cell[0], prev[1]-cell[1]) | dir(next[0]-cell[0], next[1]-cell[1])
			if heat >= mk.heat {
				mk.heat, mk.hue = heat, from.hue
			}
			mk.dotted = mk.dotted || dotted
		}
	}
	crowded := len(m.nodes) > 24
	for _, n := range m.nodes {
		parent := m.nodes[n.parent]
		if parent == nil || n.peer {
			continue
		}
		heat := m.heat[edgeKey(n.parent, n.id)]
		if crowded && heat == 0 {
			continue
		}
		draw(parent, n, heat, false)
	}
	if root := m.nodes[m.root]; root != nil {
		draw(m.nodes[agentsYou], root, m.heat[edgeKey(agentsYou, m.root)]+m.heat[edgeKey(m.root, agentsYou)], false)
	}
	for key, heat := range m.heat {
		from, to, _ := strings.Cut(key, ">")
		a, b := m.nodes[from], m.nodes[to]
		if a == nil || b == nil || b.parent == from || (from == agentsYou && to == m.root) || (to == agentsYou && from == m.root) {
			continue
		}
		draw(a, b, heat, true)
	}
	decor := agentColors().decor
	for cell, mk := range marks {
		g := agentGlyphs[mk.mask]
		if g == 0 {
			g = '·'
		}
		if mk.dotted {
			switch {
			case mk.mask&5 != 0 && mk.mask&10 == 0:
				g = '┆'
			case mk.mask&10 != 0 && mk.mask&5 == 0:
				g = '┄'
			}
		}
		c.put(cell[0], cell[1], string(g), decor.mix(mk.hue, math.Min(1, mk.heat*1.1)))
	}
}

func (m *AgentsViewModel) drawNodes(c *agentCanvas) {
	t, colors := m.clock, agentColors()
	for id, n := range m.nodes {
		glyph := "●"
		var hue rgb
		switch {
		case id == agentsYou:
			glyph, hue = "◆", colors.you
		case n.running:
			p := 0.5 + 0.5*math.Sin(t*5+n.phase)
			if p > 0.55 {
				glyph = "◉"
			}
			hue = n.hue.mix(colors.faint, 0.2).mix(n.hue, p)
		case n.closed:
			glyph, hue = "✓", n.hue.mix(colors.faint, 0.5)
		default:
			glyph = "○"
			if n.peer {
				glyph = "◇"
			}
			hue = n.hue.mix(colors.faint, 0.3)
		}
		if n.flash > 0 {
			hue = hue.mix(colors.hi, n.flash*0.7)
		}
		c.put(n.x, n.y, glyph, hue)
		name := n.name
		if w := agentsSlotW - 4; utf8.RuneCountInString(name) > w {
			name = string([]rune(name)[:w-1]) + "…"
		}
		label := n.hue.mix(colors.hi, 0.35)
		if id == m.selected {
			label = colors.hi
			c.put(n.x-1, n.y, "[", n.hue)
			c.put(n.x+2+utf8.RuneCountInString(name), n.y, "]", n.hue)
		}
		c.put(n.x+2, n.y, name, label)
		if id == agentsYou {
			continue
		}
		// The jam: five bars riding the token rate.
		var bars strings.Builder
		level := math.Min(1, n.rate/400)
		for i := range 5 {
			v := 0.0
			if n.running {
				v = 0.15 + level*(0.5+0.35*math.Sin(t*(6+float64(i)*1.7)+n.phase*float64(i+1))) + 0.15*math.Sin(t*2.3+float64(i))
			}
			bars.WriteRune(agentsBars[max(0, min(7, int(math.Round(v*7))))])
		}
		barHue := colors.decor
		if n.running {
			barHue = n.hue
		}
		c.put(n.x+2, n.y+1, bars.String(), barHue)
		if n.chars > 0 {
			c.put(n.x+8, n.y+1, compactCount(n.chars/4), colors.faint)
		}
	}
	for _, p := range m.packets {
		head := int(math.Floor(p.pos))
		for i := range p.blocks {
			idx := head - i
			if idx < 0 || idx >= len(p.path) {
				continue
			}
			glyph, hue := "▪", p.hue
			if i == 0 {
				glyph, hue = "■", p.hue.mix(colors.hi, 0.35)
			}
			c.put(p.path[idx][0], p.path[idx][1], glyph, hue)
		}
	}
	for _, f := range m.floats {
		rise := min(2, int(f.t*2.2))
		c.put(f.x, f.y-rise, f.text, f.hue.mix(colors.decor, math.Min(1, f.t/1.4)))
	}
}

func (m AgentsViewModel) paneHeader() []string {
	// One column goes to the space after the divider.
	width := m.paneWidth() - 1
	rows := make([]string, 0, 12)
	n := m.nodes[m.selected]
	if n == nil || width <= 0 {
		return rows
	}
	colors := agentColors()
	styled := func(hue rgb, s string) string { return sgr(hue.hex(), "") + s + ansiReset }
	state := "idle"
	switch {
	case n.id == agentsYou:
		state = "that's you"
	case n.running:
		state = "running"
	case n.closed:
		state = "closed"
	case n.peer:
		state = "outside this tree"
	}
	rows = append(rows, styled(n.hue, "● ")+DefaultStyles.Bold.Render(n.name)+"  "+DefaultStyles.Faint.Render(state))
	var meta []string
	if n.model != "" {
		meta = append(meta, n.model)
	}
	if n.id != agentsYou {
		meta = append(meta, fmt.Sprintf("depth %d", n.depth))
	}
	if parent := m.nodes[n.parent]; parent != nil {
		meta = append(meta, "parent "+parent.name)
	}
	rows = append(rows, DefaultStyles.Faint.Render(ansi.Truncate(strings.Join(meta, " · "), width, "…")), "")
	if len(n.mail) > 0 {
		rows = append(rows, DefaultStyles.Muted.Render("mail"))
		for _, mail := range n.mail[max(0, len(n.mail)-5):] {
			var arrow string
			if mail.incoming {
				arrow = styled(colors.mail, "← ")
			} else {
				arrow = DefaultStyles.Faint.Render("→ ")
			}
			rows = append(rows, ansi.Truncate(arrow+mail.who+" "+DefaultStyles.Faint.Render(mail.kind), width, "…"))
		}
		rows = append(rows, "")
	}
	live := DefaultStyles.Muted.Render("tail")
	if n.running {
		live += " " + styled(n.hue, "●") + DefaultStyles.Faint.Render(" live")
	}
	if n.tail.omitted || n.preview.lines.omitted {
		live += DefaultStyles.Faint.Render(" · earlier output omitted")
	}
	return append(rows, live)
}

func (m AgentsViewModel) pane(height int) []string {
	rows := m.paneHeader()
	room := max(0, height-len(rows))
	if room == 0 || len(rows) == 0 {
		return rows
	}
	wrapped := m.tailCache.rows
	if len(wrapped) == 0 {
		return append(rows, DefaultStyles.Faint.Render("nothing yet"))
	}
	return append(rows, wrapped[max(0, len(wrapped)-room):]...)
}

// drawTail wraps one tail line to width and styles it by kind.
func drawTail(line tailLine, width, limit int) []string {
	gutter, inner := "", width
	format := func(s ...string) string { return strings.Join(s, "") }
	switch line.kind {
	case tailThinking:
		format = func(s ...string) string { return DefaultStyles.Faint.Render(ansiItalic + s[0]) }
	case tailCode:
		gutter, inner, format = DefaultStyles.Decor.Render("│ "), width-2, DefaultStyles.Muted.Render
	case tailOutput:
		gutter, inner, format = DefaultStyles.Decor.Render("⎿ "), width-2, DefaultStyles.Faint.Render
	case tailMeta:
		format = DefaultStyles.Faint.Render
	}
	wrapped := ansi.Hardwrap(line.text, max(8, inner), true)
	start := len(wrapped)
	for range limit {
		index := strings.LastIndexByte(wrapped[:start], '\n')
		if index < 0 {
			start = 0
			break
		}
		start = index
	}
	if start > 0 {
		start++
	}
	var out []string
	for part := range strings.SplitSeq(wrapped[start:], "\n") {
		// A cached row must not retain the rest of a long wrapped line.
		out = append(out, gutter+format(strings.Clone(part)))
	}
	return out
}

func (m AgentsViewModel) View() string {
	if m.Width <= 0 || m.Height <= 0 {
		return ""
	}
	live, tokens := 0, 0
	for id, n := range m.nodes {
		if id == agentsYou {
			continue
		}
		if n.running {
			live++
		}
		tokens += n.chars / 4
	}
	right := DefaultStyles.Faint.Render(fmt.Sprintf("%d agents · %d running · ▴%s tok", len(m.nodes)-1, live, compactCount(tokens)))
	out := []string{titleRule(m.Width, brand("albedo")+" "+DefaultStyles.Muted.Render("/agents"), right)}

	var confirmRows []string
	if m.confirm != "" {
		what := m.label(m.confirm, "")
		if below := m.below(m.confirm); below == 1 {
			what += " and the agent below it"
		} else if below > 1 {
			what += fmt.Sprintf(" and the %d agents below it", below)
		}
		for line := range strings.SplitSeq(ansi.Wrap("Their transcripts and work will also be deleted. Delete "+what+"?", max(1, m.Width), " "), "\n") {
			confirmRows = append(confirmRows, DefaultStyles.Warning.Render(line))
		}
		confirmRows = append(confirmRows, keyHints(hint{"y", "delete"}, hint{"any key", "keep"}))
	}
	bodyH := max(1, m.Height-3-max(1, len(confirmRows)))
	dagW := m.dagWidth()
	// Scroll so the selected dot stays in view on a tall swarm.
	offset := 0
	if n := m.nodes[m.selected]; n != nil && n.y+3 > bodyH {
		offset = n.y + 3 - bodyH
	}
	canvas := newCanvas(dagW, bodyH+offset)
	m.drawEdges(canvas)
	m.drawNodes(canvas)
	pane := m.pane(bodyH)
	divider := DefaultStyles.Decor.Render("│")
	pw := m.paneWidth()
	for y := range bodyH {
		row := canvas.line(y + offset)
		if pw > 0 {
			side := ""
			if y < len(pane) {
				side = pane[y]
			}
			row += divider + " " + ansi.Truncate(side, pw-1, "…")
		}
		out = append(out, row)
	}

	status := ""
	switch {
	case m.rename.active():
		status = DefaultStyles.Muted.Render("rename ") + DefaultStyles.Bold.Render(m.label(m.rename.id, ""))
		if n := m.nodes[m.rename.id]; n != nil && n.address != "" {
			status += DefaultStyles.Faint.Render(" · its family can still mail it at ") + DefaultStyles.Muted.Render(n.address)
		}
	case m.err != nil:
		status = DefaultStyles.Error.Render(m.err.Error() + " · ctrl+l retries")
	case m.noticeT > 0:
		status = DefaultStyles.Muted.Render(m.notice)
	}
	if len(confirmRows) > 0 {
		out = append(out, confirmRows...)
	} else {
		out = append(out, status)
	}
	target := m.label(m.selected, "agent")
	input := m.input.View()
	if m.input.Value() == "" {
		input = DefaultStyles.Faint.Render("message " + target + "…  or /spawn <name> <task>")
	}
	if n := m.nodes[m.rename.id]; n != nil && m.rename.active() {
		out = append(out, DefaultStyles.Prompt.Render("✎ ")+m.rename.view(m.Width-promptMarkWidth), renameHints("restores "+renameBlank(n)))
	} else {
		out = append(out, promptLead()+input, keyHints(hint{"tab", "next agent"}, hint{"enter", "open or send"}, hint{"ctrl+r", "rename"}, hint{"ctrl+x", "delete"}, hint{"esc", "back"}))
	}
	return strings.Join(out, "\n")
}
