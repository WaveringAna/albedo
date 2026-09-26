package tui

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"math"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"albedo/cli/internal/daemon"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
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
type agentsFrameMsg struct{ Gen int }
type agentsSentMsg struct {
	Gen    int
	Notice string
	Err    error
}

type agentWire struct {
	Session daemon.Session `json:"session"`
	Running bool           `json:"running"`
	Parent  *string        `json:"parent"`
	Name    string         `json:"name"`
	Depth   int            `json:"depth"`
	Closed  bool           `json:"closed"`
}

type agentMail struct {
	incoming bool
	who      string
	kind     string
	text     string
}

type agentNode struct {
	id, parent, name, model string
	depth                   int
	running, closed         bool
	peer                    bool // reached by mail, outside the tree
	session                 daemon.Session
	chars                   int
	rate                    float64
	flash                   float64
	phase                   float64
	tail                    []string
	line                    string
	mail                    []agentMail
	hue                     rgb
	x, y                    int
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
	notice   string
	noticeT  float64
	err      error
	input    textinput.Model
	cancel   context.CancelFunc
	events   chan []map[string]any
}

const agentsYou = "you"

var (
	agentsBars    = []rune("▁▂▃▄▅▆▇█")
	agentsFrame   = 70 * time.Millisecond
	agentsSlotW   = 16
	agentsLevelGp = 2
)

func NewAgentsViewModel(conn *daemon.Connection, sessionID string) AgentsViewModel {
	input := textinput.New()
	input.Prompt = ""
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
	return tea.Batch(m.snapshotCmd(m.Gen), m.startStream(m.Gen), m.frameCmd(m.Gen), textinput.Blink)
}

// Close stops the stream; the view is gone once the app leaves it.
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
			return agentsSnapshotMsg{Gen: gen, Err: fmt.Errorf("daemon connection unavailable")}
		}
		tree, err := daemon.Request[struct {
			Root  string      `json:"root"`
			Nodes []agentWire `json:"nodes"`
		}](context.Background(), conn, "/agents?session="+url.QueryEscape(id), nil)
		return agentsSnapshotMsg{Gen: gen, Root: tree.Root, Nodes: tree.Nodes, Err: err}
	}
}

// startStream reads the daemon's agents stream into a channel the view drains
// one batch at a time.
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
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, conn.BaseURL()+"/agents/stream", nil)
		if err != nil {
			return
		}
		req.Header.Set("Accept", "text/event-stream")
		req.Header.Set("Authorization", "Bearer "+conn.AuthToken())
		res, err := conn.HTTPClient().Do(req)
		if err != nil {
			return
		}
		defer res.Body.Close()
		if res.StatusCode != http.StatusOK {
			return
		}
		scanner := bufio.NewScanner(res.Body)
		scanner.Buffer(make([]byte, 64*1024), 8*1024*1024)
		for scanner.Scan() {
			line := scanner.Text()
			if !strings.HasPrefix(line, "data:") {
				continue
			}
			var batch struct {
				Events []map[string]any `json:"events"`
			}
			if json.Unmarshal([]byte(strings.TrimSpace(line[5:])), &batch) != nil || len(batch.Events) == 0 {
				continue
			}
			select {
			case events <- batch.Events:
			case <-ctx.Done():
				return
			}
		}
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

func (m AgentsViewModel) Update(msg tea.Msg) (AgentsViewModel, tea.Cmd) {
	switch msg := msg.(type) {
	case agentsSnapshotMsg:
		if msg.Gen != m.Gen {
			return m, nil
		}
		if msg.Err != nil {
			m.err = msg.Err
			return m, nil
		}
		m.err = nil
		m.root = msg.Root
		for _, wire := range msg.Nodes {
			n := m.node(wire.Session.ID, wire.Name)
			n.session = wire.Session
			n.model = wire.Session.Model
			n.depth = wire.Depth
			n.running = wire.Running
			n.closed = wire.Closed
			n.peer = false
			if wire.Parent != nil {
				n.parent = *wire.Parent
			}
		}
		m.layout()
		return m, nil

	case agentsEventsMsg:
		if msg.Gen != m.Gen {
			return m, nil
		}
		relayout := false
		for _, event := range msg.Events {
			if m.apply(event) {
				relayout = true
			}
		}
		if relayout {
			m.layout()
		}
		return m, waitAgents(m.events, m.Gen)

	case agentsStreamClosedMsg:
		if msg.Gen != m.Gen {
			return m, nil
		}
		// The daemon restarted or the connection dropped: reconnect shortly.
		gen := m.Gen
		return m, tea.Tick(time.Second, func(time.Time) tea.Msg { return agentsReconnectMsg{Gen: gen} })

	case agentsReconnectMsg:
		if msg.Gen != m.Gen {
			return m, nil
		}
		return m, tea.Batch(m.snapshotCmd(m.Gen), m.startStream(m.Gen))

	case agentsFrameMsg:
		if msg.Gen != m.Gen {
			return m, nil
		}
		m.step()
		return m, m.frameCmd(m.Gen)

	case agentsSentMsg:
		if msg.Gen != m.Gen {
			return m, nil
		}
		if msg.Err != nil {
			m.say("could not send: " + msg.Err.Error())
		} else if msg.Notice != "" {
			m.say(msg.Notice)
		}
		return m, nil

	case tea.KeyMsg:
		return m.key(msg)
	}
	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	return m, cmd
}

type agentsReconnectMsg struct{ Gen int }

func (m AgentsViewModel) key(msg tea.KeyMsg) (AgentsViewModel, tea.Cmd) {
	empty := m.input.Value() == ""
	switch {
	case msg.Type == tea.KeyEsc || msg.Type == tea.KeyCtrlC || msg.Type == tea.KeyCtrlG:
		if !empty && msg.Type == tea.KeyEsc {
			m.input.SetValue("")
			return m, nil
		}
		return m, func() tea.Msg { return AgentsDoneMsg{} }
	case msg.Type == tea.KeyTab, empty && (msg.Type == tea.KeyRight || msg.Type == tea.KeyDown):
		m.cycle(1)
		return m, nil
	case msg.Type == tea.KeyShiftTab, empty && (msg.Type == tea.KeyLeft || msg.Type == tea.KeyUp):
		m.cycle(-1)
		return m, nil
	case msg.Type == tea.KeyEnter:
		text := strings.TrimSpace(m.input.Value())
		n := m.nodes[m.selected]
		if n == nil {
			return m, nil
		}
		if text == "" {
			if n.session.ID == "" {
				n.session = daemon.Session{ID: n.id, Title: n.name, Model: n.model}
			}
			session := n.session
			return m, func() tea.Msg { return AgentsAttachMsg{Session: session} }
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

func (m AgentsViewModel) sendCmd(id, text string) tea.Cmd {
	conn, gen := m.Conn, m.Gen
	return func() tea.Msg {
		path := fmt.Sprintf("/sessions/%s/events", url.PathEscape(id))
		_, err := daemon.Request[map[string]any](context.Background(), conn, path, map[string]any{"content": text})
		return agentsSentMsg{Gen: gen, Err: err}
	}
}

func (m AgentsViewModel) spawnCmd(parent, name, task string) tea.Cmd {
	conn, gen := m.Conn, m.Gen
	return func() tea.Msg {
		if name == "" || task == "" {
			return agentsSentMsg{Gen: gen, Err: fmt.Errorf("type /spawn <name> <task>")}
		}
		path := fmt.Sprintf("/sessions/%s/children", url.PathEscape(parent))
		_, err := daemon.Request[map[string]any](context.Background(), conn, path, map[string]any{"name": name, "task": task})
		if err != nil {
			return agentsSentMsg{Gen: gen, Err: err}
		}
		return agentsSentMsg{Gen: gen, Notice: "spawned " + name}
	}
}

func (m *AgentsViewModel) say(text string) {
	m.notice = text
	m.noticeT = 3
}

func (m *AgentsViewModel) cycle(d int) {
	if len(m.order) == 0 {
		return
	}
	i := 0
	for j, id := range m.order {
		if id == m.selected {
			i = j
		}
	}
	m.selected = m.order[(i+d+len(m.order))%len(m.order)]
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
	if len(id) > 8 {
		return id[:8]
	}
	return id
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
		n.parent = parent
		n.depth = int(num(event, "depth"))
		n.model = str(event, "model")
		n.peer = false
		n.flash = 1
		return true
	case "gone":
		if _, ok := m.nodes[id]; ok {
			delete(m.nodes, id)
			if m.selected == id {
				m.selected = m.root
			}
			return true
		}
		return false
	case "mail":
		from, _ := event["from"].(string)
		to := str(event, "to")
		fromName := str(event, "fromName")
		changed := false
		if _, ok := m.nodes[to]; !ok {
			m.node(to, "").peer = true
			changed = true
		}
		source := agentsYou
		if from != "" {
			if _, ok := m.nodes[from]; !ok {
				m.node(from, fromName).peer = true
				changed = true
			}
			source = from
		}
		if changed {
			m.layout()
		}
		bytes := int(num(event, "bytes"))
		mailKind := str(event, "kind")
		label := mailKind
		if n := m.nodes[to]; n != nil {
			n.mail = appendMail(n.mail, agentMail{incoming: true, who: m.label(source, fromName), kind: label})
		}
		if n := m.nodes[source]; n != nil {
			n.mail = appendMail(n.mail, agentMail{incoming: false, who: m.label(to, ""), kind: label})
		}
		m.send(source, to, max(1, bytes/4))
		return false
	}
	n, ok := m.nodes[id]
	if !ok {
		return false
	}
	switch kind {
	case "running":
		running, _ := event["running"].(bool)
		n.running = running
		if !running {
			m.flushLine(n)
		}
	case "text":
		text := str(event, "text")
		n.chars += utf8.RuneCountInString(text)
		n.rate += float64(len(text))
		for {
			head, rest, found := strings.Cut(text, "\n")
			n.line += head
			if !found {
				break
			}
			m.flushLine(n)
			text = rest
		}
	case "thinking":
		n.rate += num(event, "n") / 4
	case "tool_progress":
		progress, _ := event["progress"].(map[string]any)
		if str(progress, "phase") == "running" {
			m.flushLine(n)
			m.pushTail(n, "▸ "+str(progress, "name"))
		}
	case "user":
		// Mail already travelled as a packet; a person typing is new.
		if str(event, "source") == "chat" {
			m.send(agentsYou, id, max(1, len(str(event, "text"))/4))
		}
	case "message":
		// A root's answer goes back to you.
		if n.parent == "" && !n.peer {
			m.send(id, agentsYou, max(1, len(str(event, "text"))/4))
		}
	case "error":
		m.pushTail(n, "✕ "+str(event, "text"))
	case "interrupted":
		m.flushLine(n)
		m.pushTail(n, "· interrupted")
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
	if fallback != "" {
		return fallback
	}
	return shortID(id)
}

func appendMail(list []agentMail, mail agentMail) []agentMail {
	list = append(list, mail)
	if len(list) > 12 {
		list = list[len(list)-12:]
	}
	return list
}

func num(event map[string]any, key string) float64 {
	v, _ := event[key].(float64)
	return v
}

func (m *AgentsViewModel) flushLine(n *agentNode) {
	if strings.TrimSpace(n.line) != "" {
		m.pushTail(n, n.line)
	}
	n.line = ""
}

func (m *AgentsViewModel) pushTail(n *agentNode, line string) {
	n.tail = append(n.tail, strings.TrimSpace(line))
	if len(n.tail) > 40 {
		n.tail = n.tail[len(n.tail)-40:]
	}
}

// ─── layout ───

func (m *AgentsViewModel) dagWidth() int {
	if m.Width >= 96 {
		return m.Width - m.paneWidth() - 1
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
		sort.Strings(list)
	}
	sort.Strings(roots)
	sort.Strings(peers)
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
		for i, j := 0, len(cells)-1; i < j; i, j = i+1, j-1 {
			cells[i], cells[j] = cells[j], cells[i]
		}
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
	key := edgeKey(from, to)
	if b.parent == from {
		key = edgeKey(from, to)
	} else if a.parent == to {
		key = edgeKey(to, from)
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
		busy := false
		for _, p := range m.packets {
			if p.edge == key {
				busy = true
			}
		}
		if !busy {
			h -= dt * 0.8
			if h <= 0 {
				delete(m.heat, key)
				continue
			}
			m.heat[key] = h
		}
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

func compactCount(n int) string {
	if n >= 1000 {
		return fmt.Sprintf("%.1fk", float64(n)/1000)
	}
	return fmt.Sprintf("%d", n)
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
	for _, r := range s {
		if x >= 0 && x < c.w && y >= 0 && y < c.h {
			h := hue
			c.cells[y][x] = agentCell{r: r, hue: &h}
		}
		x++
	}
}

var sgrCache = map[string]string{}

func (c *agentCanvas) line(y int) string {
	var b strings.Builder
	current := ""
	for _, cell := range c.cells[y] {
		seq := ""
		if cell.hue != nil && cell.r != ' ' {
			hex := cell.hue.hex()
			if cached, ok := sgrCache[hex]; ok {
				seq = cached
			} else {
				seq = sgr(hex, "")
				sgrCache[hex] = seq
			}
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
	draw := func(from, to *agentNode, heat float64, dotted bool) {
		cells := append([][2]int{{from.x, from.y}}, route(from, to)...)
		for i := 1; i < len(cells); i++ {
			cell, prev := cells[i], cells[i-1]
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
			mk := marks[cell]
			if mk == nil {
				mk = &mark{hue: from.hue}
				marks[cell] = mk
			}
			mk.mask |= dir(prev[0]-cell[0], prev[1]-cell[1])
			if i+1 < len(cells) {
				next := cells[i+1]
				mk.mask |= dir(next[0]-cell[0], next[1]-cell[1])
			} else {
				mk.mask |= dir(to.x-cell[0], to.y-cell[1])
			}
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
	for cell, mk := range marks {
		g, ok := agentGlyphs[mk.mask]
		if !ok {
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
		c.put(cell[0], cell[1], string(g), agentColors().decor.mix(mk.hue, math.Min(1, mk.heat*1.1)))
	}
}

func (m *AgentsViewModel) drawNodes(c *agentCanvas) {
	t := m.clock
	for id, n := range m.nodes {
		glyph, hue := "●", n.hue
		switch {
		case id == agentsYou:
			glyph, hue = "◆", agentColors().you
		case n.running:
			p := 0.5 + 0.5*math.Sin(t*5+n.phase)
			if p > 0.55 {
				glyph = "◉"
			}
			hue = n.hue.mix(agentColors().faint, 0.2).mix(n.hue, p)
		case n.closed:
			glyph, hue = "✓", n.hue.mix(agentColors().faint, 0.5)
		case n.peer:
			glyph, hue = "◇", n.hue.mix(agentColors().faint, 0.3)
		default:
			glyph, hue = "○", n.hue.mix(agentColors().faint, 0.3)
		}
		if n.flash > 0 {
			hue = hue.mix(agentColors().hi, n.flash*0.7)
		}
		c.put(n.x, n.y, glyph, hue)
		name := n.name
		if w := agentsSlotW - 4; utf8.RuneCountInString(name) > w {
			name = string([]rune(name)[:w-1]) + "…"
		}
		label := n.hue.mix(agentColors().hi, 0.35)
		if id == m.selected {
			label = agentColors().hi
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
		barHue := agentColors().decor
		if n.running {
			barHue = n.hue
		}
		c.put(n.x+2, n.y+1, bars.String(), barHue)
		if n.chars > 0 {
			c.put(n.x+8, n.y+1, compactCount(n.chars/4), agentColors().faint)
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
				glyph, hue = "■", p.hue.mix(agentColors().hi, 0.35)
			}
			c.put(p.path[idx][0], p.path[idx][1], glyph, hue)
		}
	}
	for _, f := range m.floats {
		rise := min(2, int(f.t*2.2))
		c.put(f.x, f.y-rise, f.text, f.hue.mix(agentColors().decor, math.Min(1, f.t/1.4)))
	}
}

func (m AgentsViewModel) pane(height int) []string {
	width := m.paneWidth()
	rows := make([]string, 0, height)
	n := m.nodes[m.selected]
	if n == nil || width == 0 {
		return rows
	}
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
			arrow := DefaultStyles.Faint.Render("→ ")
			if mail.incoming {
				arrow = styled(agentColors().mail, "← ")
			}
			rows = append(rows, ansi.Truncate(arrow+mail.who+" "+DefaultStyles.Faint.Render(mail.kind), width, "…"))
		}
		rows = append(rows, "")
	}
	rows = append(rows, DefaultStyles.Muted.Render("tail"))
	lines := append([]string{}, n.tail...)
	if strings.TrimSpace(n.line) != "" {
		lines = append(lines, n.line)
	}
	var wrapped []string
	for _, line := range lines {
		for _, part := range strings.Split(ansi.Wordwrap(line, width, ""), "\n") {
			wrapped = append(wrapped, part)
		}
	}
	room := height - len(rows)
	if room > 0 && len(wrapped) > room {
		wrapped = wrapped[len(wrapped)-room:]
	}
	for _, line := range wrapped {
		if strings.HasPrefix(line, "▸") {
			rows = append(rows, DefaultStyles.Faint.Render(line))
		} else {
			rows = append(rows, line)
		}
	}
	if len(wrapped) == 0 {
		rows = append(rows, DefaultStyles.Faint.Render("nothing yet"))
	}
	return rows
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

	bodyH := max(3, m.Height-4)
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
	for y := range bodyH {
		row := canvas.line(y + offset)
		if m.paneWidth() > 0 {
			side := ""
			if y < len(pane) {
				side = pane[y]
			}
			row += divider + " " + ansi.Truncate(side, m.paneWidth()-1, "…")
		}
		out = append(out, row)
	}

	status := ""
	switch {
	case m.err != nil:
		status = DefaultStyles.Error.Render(m.err.Error())
	case m.noticeT > 0:
		status = DefaultStyles.Muted.Render(m.notice)
	}
	out = append(out, status)
	target := "agent"
	if n := m.nodes[m.selected]; n != nil {
		target = n.name
	}
	input := m.input.View()
	if m.input.Value() == "" {
		input = DefaultStyles.Faint.Render("message " + target + "…  or /spawn <name> <task>")
	}
	out = append(out, promptLead()+input)
	out = append(out, keyHints(hint{"tab", "next agent"}, hint{"enter", "open or send"}, hint{"esc", "back"}))
	return strings.Join(out, "\n")
}
