package uv

// NormalBorder returns a standard-type border with a normal weight and 90
// degree corners.
func NormalBorder() Border {
	return Border{
		Top:         Side{Content: "─"},
		Bottom:      Side{Content: "─"},
		Left:        Side{Content: "│"},
		Right:       Side{Content: "│"},
		TopLeft:     Side{Content: "┌"},
		TopRight:    Side{Content: "┐"},
		BottomLeft:  Side{Content: "└"},
		BottomRight: Side{Content: "┘"},
	}
}

// RoundedBorder returns a border with rounded corners.
func RoundedBorder() Border {
	return Border{
		Top:         Side{Content: "─"},
		Bottom:      Side{Content: "─"},
		Left:        Side{Content: "│"},
		Right:       Side{Content: "│"},
		TopLeft:     Side{Content: "╭"},
		TopRight:    Side{Content: "╮"},
		BottomLeft:  Side{Content: "╰"},
		BottomRight: Side{Content: "╯"},
	}
}

// BlockBorder returns a border that takes the whole block.
func BlockBorder() Border {
	return Border{
		Top:         Side{Content: "█"},
		Bottom:      Side{Content: "█"},
		Left:        Side{Content: "█"},
		Right:       Side{Content: "█"},
		TopLeft:     Side{Content: "█"},
		TopRight:    Side{Content: "█"},
		BottomLeft:  Side{Content: "█"},
		BottomRight: Side{Content: "█"},
	}
}

// OuterHalfBlockBorder returns a half-block border that sits outside the frame.
func OuterHalfBlockBorder() Border {
	return Border{
		Top:         Side{Content: "▀"},
		Bottom:      Side{Content: "▄"},
		Left:        Side{Content: "▌"},
		Right:       Side{Content: "▐"},
		TopLeft:     Side{Content: "▛"},
		TopRight:    Side{Content: "▜"},
		BottomLeft:  Side{Content: "▙"},
		BottomRight: Side{Content: "▟"},
	}
}

// InnerHalfBlockBorder returns a half-block border that sits inside the frame.
func InnerHalfBlockBorder() Border {
	return Border{
		Top:         Side{Content: "▄"},
		Bottom:      Side{Content: "▀"},
		Left:        Side{Content: "▐"},
		Right:       Side{Content: "▌"},
		TopLeft:     Side{Content: "▗"},
		TopRight:    Side{Content: "▖"},
		BottomLeft:  Side{Content: "▝"},
		BottomRight: Side{Content: "▘"},
	}
}

// ThickBorder returns a border that's thicker than the one returned by
// NormalBorder.
func ThickBorder() Border {
	return Border{
		Top:         Side{Content: "━"},
		Bottom:      Side{Content: "━"},
		Left:        Side{Content: "┃"},
		Right:       Side{Content: "┃"},
		TopLeft:     Side{Content: "┏"},
		TopRight:    Side{Content: "┓"},
		BottomLeft:  Side{Content: "┗"},
		BottomRight: Side{Content: "┛"},
	}
}

// DoubleBorder returns a border comprised of two thin strokes.
func DoubleBorder() Border {
	return Border{
		Top:         Side{Content: "═"},
		Bottom:      Side{Content: "═"},
		Left:        Side{Content: "║"},
		Right:       Side{Content: "║"},
		TopLeft:     Side{Content: "╔"},
		TopRight:    Side{Content: "╗"},
		BottomLeft:  Side{Content: "╚"},
		BottomRight: Side{Content: "╝"},
	}
}

// HiddenBorder returns a border that renders as a series of single-cell
// spaces. It's useful for cases when you want to remove a standard border but
// maintain layout positioning. This said, you can still apply a background
// color to a hidden border.
func HiddenBorder() Border {
	return Border{
		Top:         Side{Content: " "},
		Bottom:      Side{Content: " "},
		Left:        Side{Content: " "},
		Right:       Side{Content: " "},
		TopLeft:     Side{Content: " "},
		TopRight:    Side{Content: " "},
		BottomLeft:  Side{Content: " "},
		BottomRight: Side{Content: " "},
	}
}

// MarkdownBorder return a table border in markdown style.
func MarkdownBorder() Border {
	return Border{
		Left:        Side{Content: "|"},
		Right:       Side{Content: "|"},
		TopLeft:     Side{Content: "|"},
		TopRight:    Side{Content: "|"},
		BottomLeft:  Side{Content: "|"},
		BottomRight: Side{Content: "|"},
	}
}

// ASCIIBorder returns a table border with ASCII characters.
func ASCIIBorder() Border {
	return Border{
		Top:         Side{Content: "-"},
		Bottom:      Side{Content: "-"},
		Left:        Side{Content: "|"},
		Right:       Side{Content: "|"},
		TopLeft:     Side{Content: "+"},
		TopRight:    Side{Content: "+"},
		BottomLeft:  Side{Content: "+"},
		BottomRight: Side{Content: "+"},
	}
}

// Side represents a single border side with its properties.
type Side struct {
	Content string
	Style
	Link
}

// Border represents a border with its properties.
type Border struct {
	Top         Side
	Bottom      Side
	Left        Side
	Right       Side
	TopLeft     Side
	TopRight    Side
	BottomLeft  Side
	BottomRight Side
}

// Style returns a new [Border] with the given style applied to all [Side]s.
func (b Border) Style(style Style) Border {
	b.Top.Style = style
	b.Bottom.Style = style
	b.Left.Style = style
	b.Right.Style = style
	b.TopLeft.Style = style
	b.TopRight.Style = style
	b.BottomLeft.Style = style
	b.BottomRight.Style = style
	return b
}

// Link returns a new [Border] with the given link applied to all [Side]s.
func (b Border) Link(link Link) Border {
	b.Top.Link = link
	b.Bottom.Link = link
	b.Left.Link = link
	b.Right.Link = link
	b.TopLeft.Link = link
	b.TopRight.Link = link
	b.BottomLeft.Link = link
	b.BottomRight.Link = link
	return b
}

// Draw draws the border around the given component.
func (b *Border) Draw(scr Screen, area Rectangle) {
	// A side is the same cell along its whole run, and a screen copies the
	// cells it is given, so one cell per side is enough.
	top, bottom := borderCell(scr, &b.Top), borderCell(scr, &b.Bottom)
	left, right := borderCell(scr, &b.Left), borderCell(scr, &b.Right)
	topLeft, topRight := borderCell(scr, &b.TopLeft), borderCell(scr, &b.TopRight)
	bottomLeft, bottomRight := borderCell(scr, &b.BottomLeft), borderCell(scr, &b.BottomRight)

	for y := area.Min.Y; y < area.Max.Y; y++ {
		for x := area.Min.X; x < area.Max.X; x++ {
			var cell *Cell
			switch {
			case y == area.Min.Y && x == area.Min.X:
				cell = topLeft
			case y == area.Min.Y && x == area.Max.X-1:
				cell = topRight
			case y == area.Max.Y-1 && x == area.Min.X:
				cell = bottomLeft
			case y == area.Max.Y-1 && x == area.Max.X-1:
				cell = bottomRight
			case y == area.Min.Y:
				cell = top
			case y == area.Max.Y-1:
				cell = bottom
			case x == area.Min.X:
				cell = left
			case x == area.Max.X-1:
				cell = right
			default:
				continue
			}
			if cell == nil {
				continue
			}
			scr.SetCell(x, y, cell)
		}
	}
}

func borderCell(scr Screen, b *Side) *Cell {
	c := NewCell(scr.WidthMethod(), b.Content)
	if c != nil {
		c.Style = StyleRef(b.Style)
		c.Link = LinkRef(b.Link)
	}
	return c
}
