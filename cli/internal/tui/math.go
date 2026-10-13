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
	open, close string
	tex         []byte
	closed      bool
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

// mathCloser is the delimiter that closes math opened at the start of line,
// and the opener's length.
func mathCloser(line []byte) (string, int) {
	switch {
	case bytes.HasPrefix(line, []byte("$$")):
		return "$$", 2
	case bytes.HasPrefix(line, []byte(`\[`)):
		return `\]`, 2
	case bytes.HasPrefix(line, []byte(`\(`)):
		return `\)`, 2
	case bytes.HasPrefix(line, []byte("$")):
		return "$", 1
	}
	return "", 0
}

// displayMathLeftOpen is the closer of display math that line opens and
// does not close, or "".
func displayMathLeftOpen(line string) string {
	closer, width := mathCloser([]byte(line))
	if (closer != "$$" && closer != `\]`) || strings.Contains(line[width:], closer) {
		return ""
	}
	return closer
}

type displayMathParser struct{}

func (displayMathParser) Trigger() []byte { return []byte{'$', '\\'} }

// Open starts display math on a line that begins with $$ or \[ and, if it
// closes on the same line, has nothing after the closer.
func (displayMathParser) Open(_ ast.Node, reader text.Reader, pc parser.Context) (ast.Node, parser.State) {
	line, _ := reader.PeekLine()
	pos := pc.BlockOffset()
	if pos < 0 {
		return nil, parser.NoChildren
	}
	closer, width := mathCloser(line[pos:])
	if closer != "$$" && closer != `\]` {
		return nil, parser.NoChildren
	}
	node := &displayMath{open: string(line[pos : pos+width]), close: closer}
	rest := line[pos+width:]
	if end := bytes.Index(rest, []byte(closer)); end >= 0 {
		if !util.IsBlank(rest[end+len(closer):]) {
			return nil, parser.NoChildren
		}
		node.tex, node.closed = append(node.tex, rest[:end]...), true
	} else {
		node.tex = append(node.tex, rest...)
	}
	reader.AdvanceToEOL()
	return node, parser.NoChildren
}

func (displayMathParser) Continue(node ast.Node, reader text.Reader, _ parser.Context) parser.State {
	n := node.(*displayMath)
	if n.closed {
		return parser.Close
	}
	line, _ := reader.PeekLine()
	if end := bytes.Index(line, []byte(n.close)); end >= 0 {
		n.tex, n.closed = append(n.tex, line[:end]...), true
		reader.AdvanceToEOL()
		return parser.Close
	}
	n.tex = append(n.tex, line...)
	reader.AdvanceToEOL()
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
	closer, width := mathCloser(line)
	if closer == "" {
		return "", 0
	}
	if closer == "$" && (wordRune(before) || len(line) < 2 || unicode.IsSpace(rune(line[1]))) {
		return "", 0
	}
	for i := width; i < len(line) && line[i] != '\n'; i++ {
		if !bytes.HasPrefix(line[i:], []byte(closer)) {
			if closer == "$" && line[i] == '\\' {
				i++
			}
			continue
		}
		end := i + len(closer)
		after, _ := utf8.DecodeRune(line[end:])
		if closer == "$" && (unicode.IsSpace(rune(line[i-1])) || wordRune(after)) {
			continue
		}
		tex := strings.TrimSpace(string(line[width:i]))
		if tex == "" {
			return "", 0
		}
		return tex, end
	}
	return "", 0
}

func wordRune(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' }
