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
	Gen   int
	Root  string
	Nodes []agentWire
	Err   error
}

type agentsEventsMsg struct {
	Gen    int
	Events []map[string]any
}

type agentsStreamClosedMsg struct{ Gen int }

// agentsSeedMsg is an agent's recent history, so its tail starts from where
// it is rather than empty.
type agentsSeedMsg struct {
	Gen   int
	ID    string
	Items []struct {
		Type    string `json:"type"`
		Preview string `json:"preview"`
	}
}
type agentsSeedErrMsg struct {
	Gen int
	ID  string
	Err error
}

type agentsFrameMsg struct{ Gen int }
type agentsSentMsg struct {
	Gen    int
	Action string
	Notice string
	Err    error
}
type agentsReconnectMsg struct{ Gen int }

type agentsGenMsg interface{ gen() int }

func (m agentsSnapshotMsg) gen() int     { return m.Gen }
func (m agentsSeedMsg) gen() int         { return m.Gen }
func (m agentsSeedErrMsg) gen() int      { return m.Gen }
func (m agentsEventsMsg) gen() int       { return m.Gen }
func (m agentsStreamClosedMsg) gen() int { return m.Gen }
func (m agentsReconnectMsg) gen() int    { return m.Gen }
func (m agentsFrameMsg) gen() int        { return m.Gen }
func (m agentsSentMsg) gen() int         { return m.Gen }

type agentWire struct {
	Session daemon.Session `json:"session"`
	Running bool           `json:"running"`
	Parent  *string        `json:"parent"`
	Name    string         `json:"name"`
	Address *string        `json:"address"`
	Depth   int            `json:"depth"`
	Closed  bool           `json:"closed"`
}

type agentMail struct {
	incoming bool
	who      string
	kind     string
}

type agentNode struct {
	id, parent, name, model string
	address                 string // how its family mails it; a rename leaves it
	depth                   int
	running, closed         bool
	peer                    bool // reached by mail, outside the tree
	session                 daemon.Session
	chars                   int
	rate                    float64
	flash                   float64
	phase                   float64
	tail                    []tailLine
	line                    string
	lineKind                tailKind
	call                    string // the tool call whose arguments are streaming
	args                    string // its raw JSON arguments so far
	seeded                  bool
	mail                    []agentMail
	hue                     rgb
	x, y                    int
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
	kind tailKind
	text string
}

type agentPacket struct {
	path   [][2]int
	pos    float64
	blocks int
	hue    rgb
	to     string
	tokens int
	edge   string
}

type agentFloat struct {
	x, y int
	t    float64
	text string
	hue  rgb
}

type AgentsViewModel struct {
	Conn      *daemon.Connection
	SessionID string
	Width     int
	Height    int
	Gen       int

	root     string
	nodes    map[string]*agentNode
	order    []string
	selected string
	packets  []agentPacket
	floats   []agentFloat
	heat     map[string]float64
	clock    float64
	last     time.Time
	ticking  bool // a frame tick is in flight
	notice   string
	noticeT  float64
	err      error
	input    textinput.Model
	confirm  string // the agent waiting for y to delete it
	rename   renameField
	cancel   context.CancelFunc
	events   chan []map[string]any
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
}

func (m *AgentsViewModel) Init() tea.Cmd {
	m.Gen++
	m.ticking = true
	return tea.Batch(m.snapshotCmd(m.Gen), m.startStream(m.Gen), m.frameCmd(m.Gen), textinput.Blink)
}

// Close stops the stream and invalidates batches, completions, and timers
// already queued for this view.
func (m *AgentsViewModel) Close() {
	if m.cancel != nil {
		m.cancel()
		m.cancel = nil
	}
	m.Gen++
}

func (m AgentsViewModel) snapshotCmd(gen int) tea.Cmd {
	conn, id := m.Conn, m.SessionID
	return func() tea.Msg {
		if conn == nil {
			return agentsSnapshotMsg{Gen: gen, Err: errors.New("daemon connection unavailable")}
		}
		tree, err := daemon.Request[struct {
			Root  string      `json:"root"`
			Nodes []agentWire `json:"nodes"`
		}](context.Background(), conn, "/agents?session="+url.QueryEscape(id), nil)
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
	events := make(chan []map[string]any, 64)
	m.events = events
	conn := m.Conn
	go func() {
		defer close(events)
		// EOF and failures both reconnect through queue closure, so the view
		// deliberately discards the transport error here.
		_ = daemon.StreamAgents(ctx, conn, func(batch []map[string]any) error {
			// Leaving the view stops its consumer. Cancellation must release a
			// producer blocked on a full queue so it can close the HTTP body.
			select {
			case events <- batch:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		})
	}()
	return waitAgents(events, gen)
}

func waitAgents(events <-chan []map[string]any, gen int) tea.Cmd {
	return func() tea.Msg {
		batch, ok := <-events
		if !ok {
			return agentsStreamClosedMsg{Gen: gen}
		}
		return agentsEventsMsg{Gen: gen, Events: batch}
	}
}

func (m AgentsViewModel) frameCmd(gen int) tea.Cmd {
	return tea.Tick(agentsFrame, func(time.Time) tea.Msg { return agentsFrameMsg{Gen: gen} })
}

// Update handles msg, then starts the frame tick again if something began to
// move while it was stopped.
func (m AgentsViewModel) Update(msg tea.Msg) (AgentsViewModel, tea.Cmd) {
	m, cmd := m.update(msg)
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
		if msg.Err != nil {
			m.err = msg.Err
			return m, nil
		}
		m.err, m.root = nil, msg.Root
		for _, wire := range msg.Nodes {
			n := m.node(wire.Session.ID, wire.Name)
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
		m.layout()
		return m, m.seedCmd()

	case agentsSeedMsg:
		n := m.nodes[msg.ID]
		if n == nil {
			return m, nil
		}
		var seeded []tailLine
		for _, item := range msg.Items {
			switch item.Type {
			case "user", "tool":
				prefix := pick(item.Type == "tool", "▸ ", "← ")
				seeded = append(seeded, tailLine{tailMeta, prefix + firstLine(item.Preview)})
			default:
				for _, line := range strings.Split(item.Preview, "\n") {
					seeded = append(seeded, tailLine{tailText, line})
				}
			}
		}
		n.tail = append(seeded, n.tail...)
		return m, nil

	case agentsSeedErrMsg:
		// The seed died; unseed its node so the next selection tries again.
		if n := m.nodes[msg.ID]; n != nil {
			n.seeded = false
			m.say("Could not load recent messages for " + m.label(msg.ID, "this agent") + ". Select it again to retry: " + msg.Err.Error())
		}
		return m, nil

	case agentsEventsMsg:
		relayout := false
		for _, event := range msg.Events {
			relayout = m.apply(event) || relayout
		}
		if relayout {
			m.layout()
		}
		return m, waitAgents(m.events, m.Gen)

	case agentsStreamClosedMsg:
		// The daemon restarted or the connection dropped: reconnect shortly.
		return m, tea.Tick(time.Second, func(time.Time) tea.Msg { return agentsReconnectMsg(msg) })

	case agentsReconnectMsg:
		return m, tea.Batch(m.snapshotCmd(m.Gen), m.startStream(m.Gen))

	case agentsFrameMsg:
		m.step()
		if m.ticking = m.moving(); !m.ticking {
			return m, nil
		}
		return m, m.frameCmd(m.Gen)

	case agentsSentMsg:
		if msg.Err != nil {
			m.say("Could not " + msg.Action + ": " + msg.Err.Error())
		} else if msg.Notice != "" {
			m.say(msg.Notice)
		}
		return m, nil

	case sessionRenamedMsg:
		switch {
		case msg.Err != nil:
			m.say("Could not rename the session. Try again: " + msg.Err.Error())
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
	if n == nil || n.seeded || n.id == agentsYou || m.Conn == nil {
		return nil
	}
	n.seeded = true
	conn, gen, id := m.Conn, m.Gen, n.id
	return func() tea.Msg {
		path := fmt.Sprintf("/sessions/%s/preview?limit=10", url.PathEscape(id))
		res, err := daemon.Request[agentsSeedMsg](context.Background(), conn, path, nil)
		if err != nil {
			return agentsSeedErrMsg{Gen: gen, ID: id, Err: err}
		}
		res.Gen, res.ID = gen, id
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
	conn, gen, name := m.Conn, m.Gen, m.label(id, "")
	return func() tea.Msg {
		path := fmt.Sprintf("/sessions/%s?tree=1", url.PathEscape(id))
		res, err := daemon.RequestMethod[struct {
			Deleted int `json:"deleted"`
		}](context.Background(), conn, http.MethodDelete, path, nil)
		if err != nil {
			return agentsSentMsg{Gen: gen, Action: "delete " + name, Err: err}
		}
		return agentsSentMsg{Gen: gen, Notice: fmt.Sprintf("deleted %s (%d sessions)", name, res.Deleted)}
	}
}

func (m AgentsViewModel) sendCmd(id, text string) tea.Cmd {
	conn, gen, target := m.Conn, m.Gen, m.label(id, "agent")
	return func() tea.Msg {
		path := fmt.Sprintf("/sessions/%s/events", url.PathEscape(id))
		_, err := daemon.Request[map[string]any](context.Background(), conn, path, map[string]any{"content": text})
		return agentsSentMsg{Gen: gen, Action: "send a message to " + target, Err: err}
	}
}

func (m AgentsViewModel) spawnCmd(parent, name, task string) tea.Cmd {
	conn, gen := m.Conn, m.Gen
	return func() tea.Msg {
		if name == "" || task == "" {
			return agentsSentMsg{Gen: gen, Action: "start an agent", Err: errors.New("use /spawn <name> <task>")}
		}
		path := fmt.Sprintf("/sessions/%s/children", url.PathEscape(parent))
		_, err := daemon.Request[map[string]any](context.Background(), conn, path, map[string]any{"name": name, "task": task})
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

func str(event map[string]any, key string) string {
	v, _ := event[key].(string)
	return v
}

// apply folds one bus event into the view; true when the tree changed shape.
func (m *AgentsViewModel) apply(event map[string]any) bool {
	kind := str(event, "type")
	id := str(event, "session")
	switch kind {
	case "spawn":
		parent := str(event, "parent")
		if _, ok := m.nodes[parent]; !ok {
			return false
		}
		n := m.node(id, str(event, "name"))
		n.parent, n.model, n.depth = parent, str(event, "model"), int(num(event, "depth"))
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
		from, to := str(event, "from"), str(event, "to")
		fromName := str(event, "fromName")
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
		bytes, label := int(num(event, "bytes")), str(event, "kind")
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
		if n.running, _ = event["running"].(bool); !n.running {
			m.flushLine(n)
		}
	case "text", "thinking":
		text := str(event, "text")
		n.chars += utf8.RuneCountInString(text)
		n.rate += float64(len(text))
		tail := pick(kind == "thinking", tailThinking, tailText)
		m.stream(n, tail, text)
	case "arguments_delta":
		text := str(event, "text")
		n.chars += utf8.RuneCountInString(text)
		n.rate += float64(len(text))
		if call := str(event, "callId"); call != n.call || n.lineKind != tailCode {
			m.flushLine(n)
			n.call = call
		}
		n.lineKind = tailCode
		n.args += text
	case "tool_progress":
		progress, _ := event["progress"].(map[string]any)
		if str(progress, "phase") == "running" {
			m.flushLine(n)
			m.pushTail(n, tailMeta, "▸ "+str(progress, "name"))
		}
	case "tool":
		m.flushLine(n)
		for _, line := range strings.Split(str(event, "output"), "\n") {
			if strings.TrimSpace(line) != "" {
				m.pushTail(n, tailOutput, line)
			}
		}
	case "user":
		text := str(event, "text")
		m.flushLine(n)
		m.pushTail(n, tailMeta, "← "+firstLine(text))
		// Mail already travelled as a packet; a person typing is new.
		if str(event, "source") == "chat" {
			m.send(agentsYou, id, max(1, len(text)/4))
		}
	case "message":
		// A root's answer goes back to you.
		if n.parent == "" && !n.peer {
			m.send(id, agentsYou, max(1, len(str(event, "text"))/4))
		}
	case "error":
		m.pushTail(n, tailMeta, "✕ "+str(event, "text"))
	case "interrupted":
		m.flushLine(n)
		m.pushTail(n, tailMeta, "· interrupted")
	case "progress":
		m.flushLine(n)
		m.pushTail(n, tailMeta, "» "+str(event, "text"))
		n.flash = 0.6
	case "renamed":
		n.name = str(event, "name")
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

func num(event map[string]any, key string) float64 {
	v, _ := event[key].(float64)
	return v
}

// stream appends streamed text of one kind, closing a line at each newline.
func (m *AgentsViewModel) stream(n *agentNode, kind tailKind, text string) {
	if n.lineKind != kind {
		m.flushLine(n)
		n.lineKind = kind
	}
	for {
		head, rest, found := strings.Cut(text, "\n")
		n.line += head
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
		for _, line := range codeLines(n.args) {
			m.pushTail(n, tailCode, line)
		}
		n.args, n.call = "", ""
	} else if strings.TrimSpace(n.line) != "" {
		m.pushTail(n, n.lineKind, n.line)
	}
	n.line = ""
	n.lineKind = tailText
}

func (m *AgentsViewModel) pushTail(n *agentNode, kind tailKind, line string) {
	n.tail = capped(append(n.tail, tailLine{kind, strings.TrimRight(line, " ")}), 120)
}

// codeLines reads the code out of a tool call's JSON arguments while they are
// still arriving: the "code" string so far, unescaped, or the raw arguments
// for a tool without one.
func codeLines(raw string) []string {
	body := raw
	if i := strings.Index(raw, `"code"`); i >= 0 {
		rest := strings.TrimLeft(raw[i+len(`"code"`):], " :")
		if strings.HasPrefix(rest, `"`) {
			var b strings.Builder
			escaped := false
			for _, r := range rest[1:] {
				switch {
				case escaped:
					switch r {
					case 'n':
						b.WriteRune('\n')
					case 't':
						b.WriteString("    ")
					default:
						b.WriteRune(r)
					}
					escaped = false
				case r == '\\':
					escaped = true
				case r == '"':
					return strings.Split(strings.TrimRight(b.String(), "\n"), "\n")
				default:
					b.WriteRune(r)
				}
			}
			body = b.String()
		}
	}
	return strings.Split(strings.TrimRight(body, "\n"), "\n")
}

// ─── layout ───

func (m *AgentsViewModel) dagWidth() int {
	w := m.paneWidth()
	return pick(w > 0, m.Width-w-1, m.Width)
}

func (m *AgentsViewModel) paneWidth() int {
	return pick(m.Width < 96, 0, min(46, max(34, m.Width/3)))
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
	step := pick(b.x < a.x, -1, 1)
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
	key := pick(a.parent == to, edgeKey(to, from), edgeKey(from, to))
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
	return pick(n >= 1000, fmt.Sprintf("%.1fk", float64(n)/1000), fmt.Sprintf("%d", n))
}

// ─── drawing ───

type agentCell struct {
	r   rune
	hue *rgb
}

type agentCanvas struct {
	w, h  int
	cells [][]agentCell
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
			glyph = pick(p > 0.55, "◉", "●")
			hue = n.hue.mix(colors.faint, 0.2).mix(n.hue, p)
		case n.closed:
			glyph, hue = "✓", n.hue.mix(colors.faint, 0.5)
		default:
			glyph = pick(n.peer, "◇", "○")
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
		barHue := pick(n.running, n.hue, colors.decor)
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

func (m AgentsViewModel) pane(height int) []string {
	// One column goes to the space after the divider.
	width := m.paneWidth() - 1
	rows := make([]string, 0, height)
	n := m.nodes[m.selected]
	if n == nil || width == 0 {
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
			arrow := pick(mail.incoming, styled(colors.mail, "← "), DefaultStyles.Faint.Render("→ "))
			rows = append(rows, ansi.Truncate(arrow+mail.who+" "+DefaultStyles.Faint.Render(mail.kind), width, "…"))
		}
		rows = append(rows, "")
	}
	live := DefaultStyles.Muted.Render("tail")
	if n.running {
		live += " " + styled(n.hue, "●") + DefaultStyles.Faint.Render(" live")
	}
	rows = append(rows, live)
	lines := slices.Clone(n.tail)
	if n.lineKind == tailCode {
		for _, line := range codeLines(n.args) {
			lines = append(lines, tailLine{tailCode, line})
		}
	} else if n.line != "" {
		lines = append(lines, tailLine{n.lineKind, n.line})
	}
	var wrapped []string
	for _, line := range lines {
		wrapped = append(wrapped, drawTail(line, width)...)
	}
	room := height - len(rows)
	if room > 0 && len(wrapped) > room {
		wrapped = wrapped[len(wrapped)-room:]
	}
	if len(wrapped) == 0 {
		rows = append(rows, DefaultStyles.Faint.Render("nothing yet"))
	} else {
		rows = append(rows, wrapped...)
	}
	return rows
}

// drawTail wraps one tail line to width and styles it by kind.
func drawTail(line tailLine, width int) []string {
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
	var out []string
	for _, part := range strings.Split(ansi.Hardwrap(line.text, max(8, inner), true), "\n") {
		out = append(out, gutter+format(part))
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
		for _, line := range strings.Split(ansi.Wrap("Their transcripts and work will also be deleted. Delete "+what+"?", max(1, m.Width), " "), "\n") {
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
		status = DefaultStyles.Error.Render(m.err.Error())
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
