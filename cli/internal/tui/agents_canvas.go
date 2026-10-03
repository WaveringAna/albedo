package tui

import (
	"strings"

	"github.com/rivo/uniseg"

	"github.com/charmbracelet/x/ansi"
)

type agentCell struct {
	hue          *rgb
	text         string
	width        int
	continuation bool
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
			c.cells[y][x] = agentCell{text: " ", width: 1}
		}
	}
	return c
}

// clearAt removes a whole grapheme when another graph element overwrites it.
func (c *agentCanvas) clearAt(x, y int) {
	start := x
	for start > 0 && c.cells[y][start].continuation {
		start--
	}
	width := max(1, c.cells[y][start].width)
	for column := start; column < min(c.w, start+width); column++ {
		c.cells[y][column] = agentCell{text: " ", width: 1}
	}
}

func (c *agentCanvas) put(x, y int, text string, hue rgb) {
	if y < 0 || y >= c.h {
		return
	}
	graphemes := uniseg.NewGraphemes(text)
	for graphemes.Next() {
		cluster := graphemes.Str()
		width := ansi.StringWidth(cluster)
		if width == 0 {
			continue
		}
		if x >= 0 && x+width <= c.w {
			for column := x; column < x+width; column++ {
				c.clearAt(column, y)
			}
			c.cells[y][x] = agentCell{text: cluster, width: width, hue: &hue}
			for column := x + 1; column < x+width; column++ {
				c.cells[y][column] = agentCell{continuation: true}
			}
		}
		x += width
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
		if cell.continuation {
			continue
		}
		seq := ""
		if cell.hue != nil && cell.text != " " {
			seq = sgrCached(cell.hue.hex())
		}
		if seq != current {
			if current != "" {
				b.WriteString(ansiReset)
			}
			b.WriteString(seq)
			current = seq
		}
		b.WriteString(cell.text)
	}
	if current != "" {
		b.WriteString(ansiReset)
	}
	return b.String()
}
