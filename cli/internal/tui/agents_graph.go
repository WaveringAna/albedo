package tui

import (
	"fmt"
	"math"
	"slices"
	"strings"
	"time"

	"github.com/charmbracelet/x/ansi"
)

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
		name := ansi.Truncate(n.name, agentsSlotW-4, "…")
		label := n.hue.mix(colors.hi, 0.35)
		if id == m.selected {
			label = colors.hi
			c.put(n.x-1, n.y, "[", n.hue)
			c.put(n.x+2+ansi.StringWidth(name), n.y, "]", n.hue)
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
