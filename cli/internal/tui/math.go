package tui

import (
	"bytes"
	"io"
	"strings"
	"unicode"
	"unicode/utf8"

	"charm.land/glamour/v2"
	"charm.land/glamour/v2/ansi"
	"github.com/doug/termtex"
	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/parser"
	"github.com/yuin/goldmark/text"
	"github.com/yuin/goldmark/util"
)

// Math in a reply: $…$ and \(…\) inline, $$…$$ and \[…\] on lines of their
// own as display math. termtex lays both out in Unicode.
var (
	kindInlineMath  = ast.NewNodeKind("InlineMath")
	kindDisplayMath = ast.NewNodeKind("DisplayMath")
)

type inlineMath struct {
	ast.BaseInline
	tex, source string
}

func (n *inlineMath) Kind() ast.NodeKind            { return kindInlineMath }
func (n *inlineMath) Dump(source []byte, level int) { ast.DumpHelper(n, source, level, nil, nil) }

// displayMath is closed once its closing delimiter arrives; a reply still
// streaming may not have sent it yet.
type displayMath struct {
	ast.BaseBlock
	delimiter
	tex    []byte
	closed bool
}

func (n *displayMath) Kind() ast.NodeKind            { return kindDisplayMath }
func (n *displayMath) Dump(source []byte, level int) { ast.DumpHelper(n, source, level, nil, nil) }

// source is the math as written, with the closer once it arrived.
func (n *displayMath) source() string {
	written := n.open + string(n.tex)
	if n.closed {
		written += n.close
	}
	return strings.TrimRight(written, "\n")
}

type mathExtension struct{}

func (mathExtension) Extend(m goldmark.Markdown) {
	m.Parser().AddOptions(
		parser.WithBlockParsers(util.Prioritized(displayMathParser{}, 650)),
		parser.WithInlineParsers(util.Prioritized(inlineMathParser{}, 150)),
	)
}

// mathOptions add the math parsers and render their nodes in color.
func mathOptions(color *string) glamour.TermRendererOption {
	return glamour.WithOptions(
		glamour.WithExtensions(mathExtension{}),
		glamour.WithElement(kindInlineMath, func(node ast.Node, _ []byte, _ ansi.RenderContext) ansi.Element {
			return ansi.Element{Renderer: inlineMathElement{node.(*inlineMath), color}}
		}),
		glamour.WithElement(kindDisplayMath, func(node ast.Node, _ []byte, _ ansi.RenderContext) ansi.Element {
			return ansi.Element{Entering: "\n", Exiting: "\n", Renderer: displayMathElement{node.(*displayMath), color}}
		}),
	)
}

type inlineMathElement struct {
	node  *inlineMath
	color *string
}

func (e inlineMathElement) Render(w io.Writer, ctx ansi.RenderContext) error {
	return e.StyleOverrideRender(w, ctx, ansi.StylePrimitive{})
}

// StyleOverrideRender keeps the math color inside bold or a link. Math that
// needs more than one row, such as a matrix, stays as its source.
func (e inlineMathElement) StyleOverrideRender(w io.Writer, ctx ansi.RenderContext, outer ansi.StylePrimitive) error {
	outer.Color = e.color
	laid, err := termtex.Render(e.node.tex, termtex.Style{Inline: true})
	if err != nil || strings.Contains(laid, "\n") {
		laid = e.node.source
	}
	return (&ansi.BaseElement{Token: laid, Style: outer, Verbatim: true}).Render(w, ctx)
}

type displayMathElement struct {
	node  *displayMath
	color *string
}

// Render lays the math out to the block's width. Until it closes, or when
// termtex cannot read it, the source shows instead.
func (e displayMathElement) Render(w io.Writer, ctx ansi.RenderContext) error {
	laid := e.node.source()
	if e.node.closed {
		if out, err := termtex.Render(strings.TrimSpace(string(e.node.tex)), termtex.Style{Width: ctx.Width()}); err == nil {
			laid = out
		}
	}
	return (&ansi.BaseElement{Token: laid, Style: ansi.StylePrimitive{Color: e.color}, Verbatim: true}).Render(w, ctx)
}

// delimiter is one way to write math. Only display delimiters may open a
// block of their own.
type delimiter struct {
	open, close string
	display     bool
}

// delimiters are tried in order, so $$ is found before $.
var delimiters = []delimiter{
	{open: "$$", close: "$$", display: true},
	{open: `\[`, close: `\]`, display: true},
	{open: `\(`, close: `\)`},
	{open: "$", close: "$"},
}

// delimiterAt is the delimiter that opens math at the start of line.
func delimiterAt(line []byte) (delimiter, bool) {
	for _, d := range delimiters {
		if bytes.HasPrefix(line, []byte(d.open)) {
			return d, true
		}
	}
	return delimiter{}, false
}

// openDisplayMath reads a line that opens display math: its delimiter, the
// tex after the opener, and whether the line closes it too, in which case
// nothing may follow the closer.
func openDisplayMath(line []byte) (d delimiter, tex []byte, closed, ok bool) {
	d, ok = delimiterAt(line)
	if !ok || !d.display {
		return d, nil, false, false
	}
	tex, after, closed := bytes.Cut(line[len(d.open):], []byte(d.close))
	if closed && !util.IsBlank(after) {
		return d, nil, false, false
	}
	return d, tex, closed, true
}

type displayMathParser struct{}

func (displayMathParser) Trigger() []byte { return []byte{'$', '\\'} }

func (displayMathParser) Open(_ ast.Node, reader text.Reader, pc parser.Context) (ast.Node, parser.State) {
	line, _ := reader.PeekLine()
	pos := pc.BlockOffset()
	if pos < 0 {
		return nil, parser.NoChildren
	}
	d, tex, closed, ok := openDisplayMath(line[pos:])
	if !ok {
		return nil, parser.NoChildren
	}
	reader.AdvanceToEOL()
	return &displayMath{delimiter: d, tex: bytes.Clone(tex), closed: closed}, parser.NoChildren
}

func (displayMathParser) Continue(node ast.Node, reader text.Reader, _ parser.Context) parser.State {
	n := node.(*displayMath)
	if n.closed {
		return parser.Close
	}
	line, _ := reader.PeekLine()
	tex, _, closed := bytes.Cut(line, []byte(n.close))
	n.tex, n.closed = append(n.tex, tex...), closed
	reader.AdvanceToEOL()
	if closed {
		return parser.Close
	}
	return parser.Continue | parser.NoChildren
}

func (displayMathParser) Close(ast.Node, text.Reader, parser.Context) {}
func (displayMathParser) CanInterruptParagraph() bool                 { return true }
func (displayMathParser) CanAcceptIndentedLine() bool                 { return false }

type inlineMathParser struct{}

func (inlineMathParser) Trigger() []byte { return []byte{'$', '\\'} }

func (inlineMathParser) Parse(_ ast.Node, block text.Reader, _ parser.Context) ast.Node {
	line, _ := block.PeekLine()
	tex, length := scanInlineMath(line, block.PrecendingCharacter())
	if length == 0 {
		return nil
	}
	block.Advance(length)
	return &inlineMath{tex: tex, source: string(line[:length])}
}

// scanInlineMath is the math at the start of line and its length in bytes,
// or 0 when line does not start any. A lone $ follows Pandoc and goes
// further, so prices and shell variables stay text: it opens before a
// non-space that follows no word character, and closes after a non-space
// before anything but a word character.
func scanInlineMath(line []byte, before rune) (string, int) {
	d, ok := delimiterAt(line)
	lone := d.open == "$"
	if !ok || lone && (wordRune(before) || len(line) < 2 || util.IsSpace(line[1])) {
		return "", 0
	}
	body, _, _ := bytes.Cut(line, []byte{'\n'})
	for i := len(d.open); i < len(body); i++ {
		if d.close[0] == '$' && body[i] == '\\' {
			i++ // an escaped character never closes
			continue
		}
		if !bytes.HasPrefix(body[i:], []byte(d.close)) {
			continue
		}
		end := i + len(d.close)
		if after, _ := utf8.DecodeRune(body[end:]); lone && (util.IsSpace(body[i-1]) || wordRune(after)) {
			continue
		}
		tex := bytes.TrimSpace(body[len(d.open):i])
		if len(tex) == 0 {
			return "", 0
		}
		return string(tex), end
	}
	return "", 0
}

func wordRune(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' }
