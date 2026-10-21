package tui

import (
	"cmp"
	"crypto/sha256"
	"fmt"
	"regexp"
	"strings"
	"sync"

	"charm.land/glamour/v2"
	"charm.land/glamour/v2/ansi"
	"charm.land/glamour/v2/styles"
	"github.com/alecthomas/chroma/v2"
	"github.com/alecthomas/chroma/v2/formatters"
	chromastyles "github.com/alecthomas/chroma/v2/styles"
)

// HighlightLines colors lines of code the way a reply's code blocks are
// colored: the lexer chroma matched to the file, in the theme built from the
// terminal's palette. Each line is lexed alone; lines no lexer claims stay as
// they are. Lines already colored come from cache, which may be nil.
func HighlightLines(lines []string, lexer chroma.Lexer, cache *highlightCache) []string {
	if lexer == nil || len(lines) == 0 {
		return lines
	}
	style := codeStyle(transcriptInk)
	key := func(line string) highlightKey {
		return highlightKey{lexer.Config().Name, style.Name, line}
	}
	out := make([]string, len(lines))
	var missing []int
	for i, line := range lines {
		if colored, ok := cache.get(key(line)); ok {
			out[i] = colored
		} else {
			missing = append(missing, i)
		}
	}
	if len(missing) == 0 {
		return out
	}
	var tokens []chroma.Token
	for _, i := range missing {
		lexed, err := chroma.Coalesce(lexer).Tokenise(nil, lines[i])
		if err != nil {
			return lines
		}
		for token := lexed(); token != chroma.EOF; token = lexed() {
			// some lexers end every input with a newline, which would wrap a row
			token.Value = strings.ReplaceAll(token.Value, "\n", "")
			tokens = append(tokens, token)
		}
		tokens = append(tokens, chroma.Token{Type: chroma.Text, Value: "\n"})
	}
	var b strings.Builder
	if formatters.TTY256.Format(&b, style, chroma.Literator(tokens...)) != nil {
		return lines
	}
	colored := strings.Split(b.String(), "\n")
	if len(colored) != len(missing)+1 {
		return lines
	}
	for n, i := range missing {
		// the separator leaves an empty styled run on each line
		out[i] = emptyRuns.ReplaceAllString(colored[n], "")
		cache.put(key(lines[i]), out[i])
	}
	return out
}

type highlightKey struct{ lexer, theme, line string }

// highlightCache keeps one chat's colored lines up to a byte budget, then
// starts over: toggling diffs re-renders every diff in the transcript, and
// lexing is most of that work. It goes with the chat that owns it.
type highlightCache struct {
	mu    sync.Mutex
	lines map[highlightKey]string
	bytes int
}

const highlightBudget = 4 << 20

func (c *highlightCache) get(key highlightKey) (string, bool) {
	if c == nil {
		return "", false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	colored, ok := c.lines[key]
	return colored, ok
}

func (c *highlightCache) put(key highlightKey, colored string) {
	if c == nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	size := len(key.line) + len(colored)
	if c.lines == nil || c.bytes+size > highlightBudget {
		c.lines, c.bytes = map[highlightKey]string{}, 0
	}
	c.lines[key] = colored
	c.bytes += size
}

var emptyRuns = regexp.MustCompile("(\x1b\\[[0-9;]*m\x1b\\[0m)+$")

var markdownThemes sync.Mutex

// fenceOpen and fenceClose mark the rows that frame a code block.
const (
	fenceOpen  = "┌─"
	fenceClose = "└"
)

// codeFence is a code block's frame row in Decor, and quoteBar leads each
// quoted row. Both are decoration, which a copy does not carry.
func codeFence(mark string) string { return decorInk() + mark + ansiReset }
func quoteBar() string             { return decorInk() + "│ " + ansiReset }

// codeStyles builds each palette's theme once: parsing style entries into a
// chroma theme is most of a highlighting pass.
var codeStyles sync.Map

// codeStyle is the chroma theme for a palette. Its entries are ours: chroma's
// bundled themes come from a stylesheet, and a terminal's palette, made legible
// against its own background, is what this one follows. Each palette gets its
// own name, so a theme change cannot reuse the previous palette's colors.
func codeStyle(colors ink) *chroma.Style {
	if cached, ok := codeStyles.Load(colors); ok {
		return cached.(*chroma.Style)
	}
	style := chromastyles.Get("monokai")
	if colors.code != "" {
		palette := colors.code + colors.secondary + colors.brandFrom + colors.brandTo
		hash := sha256.Sum256([]byte(palette))
		style = chroma.MustNewStyle(fmt.Sprintf("albedo-%x", hash[:6]), chroma.StyleEntries{
			chroma.Text:          colors.code,
			chroma.Comment:       colors.secondary + " italic",
			chroma.Keyword:       colors.brandFrom,
			chroma.NameFunction:  colors.brandTo,
			chroma.LiteralString: colors.brandTo,
			chroma.LiteralNumber: colors.brandFrom,
		})
	}
	codeStyles.Store(colors, style)
	return style
}

// codeTheme names the palette's theme in chroma's registry: glamour looks a
// code block's theme up by name, not by value.
func codeTheme(colors ink) string {
	style := codeStyle(colors)
	markdownThemes.Lock()
	defer markdownThemes.Unlock()
	if chromastyles.Registry[style.Name] == nil {
		chromastyles.Register(style)
	}
	return style.Name
}

// accent is a markdown accent color, or the palette slot when the terminal
// did not report its colors.
func accent(hex, slot string) *string { return new(cmp.Or(hex, slot)) }

func markdownStyle() ansi.StyleConfig {
	style := styles.NoTTYStyleConfig
	zero, bold := uint(0), true
	style.Document.Margin = &zero
	style.Document.BlockPrefix, style.Document.BlockSuffix = "", ""
	style.Heading.BlockSuffix = ""
	for _, heading := range []*ansi.StyleBlock{&style.H1, &style.H2, &style.H3, &style.H4, &style.H5, &style.H6} {
		heading.Prefix = ""
		heading.Bold = &bold
		heading.Color = accent(transcriptInk.heading, "5")
	}
	style.Strong = ansi.StylePrimitive{Bold: &bold, Color: accent(transcriptInk.strong, "3")}
	style.Emph = ansi.StylePrimitive{Italic: &bold}
	style.Code = ansi.StyleBlock{StylePrimitive: ansi.StylePrimitive{Color: accent(transcriptInk.inlineCode, "2")}}
	style.LinkText = ansi.StylePrimitive{Color: accent(transcriptInk.link, "4")}
	style.List.LevelIndent = 0
	style.Table.Margin = &zero
	style.BlockQuote.IndentToken = new(quoteBar())
	style.CodeBlock.Margin = &zero
	style.CodeBlock.BlockPrefix = codeFence(fenceOpen) + "\n"
	style.CodeBlock.BlockSuffix = codeFence(fenceClose)
	style.HorizontalRule.Format = "\n────────────\n"
	if transcriptInk.decor != "" {
		style.HorizontalRule.Color = &transcriptInk.decor
	}
	style.CodeBlock.Theme = codeTheme(transcriptInk)
	return style
}

// RenderMarkdownAnsi renders text block by block. Glamour spaces a block by
// the one before it and no further, so each block renders once.
func RenderMarkdownAnsi(text string, width int) string {
	return renderBlocks(text, cmp.Or(max(0, width), 80), true)
}

// renderGrowing is RenderMarkdownAnsi for a reply streaming in: its last
// block is still growing, so it is rendered again each time and not kept.
func renderGrowing(text string, width int) string {
	return renderBlocks(text, cmp.Or(max(0, width), 80), false)
}

// renderCopyable renders text to width with its wrapped rows marked, so a
// copy can join them back into the lines they were.
func renderCopyable(text string, width int) string {
	return markWraps(RenderMarkdownAnsi(text, width), renderBlocks(text, 0, true))
}

// renderBlocks is text rendered at width, or unwrapped at 0. Unless whole,
// its last block may still grow and is not cached.
func renderBlocks(text string, width int, whole bool) string {
	var scan growingMarkdown
	finished, open, ok := scan.grow(text, width, whole)
	if !ok {
		return strings.Trim(renderMarkdown(text, width), " \n")
	}
	var b strings.Builder
	for _, piece := range finished {
		b.WriteString(piece)
	}
	b.WriteString(open)
	return strings.Trim(b.String(), " \n")
}

// growingMarkdown is a markdown text rendered as it arrives. The blocks that
// are finished are rendered once; each step renders only the block still
// growing, so the cost of a draw follows what arrived, not the length of the
// reply. A whole rendering stays equal to a stepwise one: both are the same
// pieces in the same order.
type growingMarkdown struct {
	// width is what the pieces were rendered at: text rendered at another one
	// cannot extend them.
	width int
	// text is the text scanned so far and scanned is how far into it the scan
	// went, with fence and blank the state there; blockStart is where the
	// block still growing begins, and prev the finished block it follows.
	text                string
	scanned, blockStart int
	fence               string
	blank               bool
	prev                string
	// started is whether a block has finished: the piece that finishes first
	// carries the rendering's start, which a whole rendering trims.
	started bool
	// unsplit is set when a line reaches across blank lines, so the text has to
	// be rendered in one piece.
	unsplit bool
}

// grow scans text, which must extend the text scanned before, and returns the
// rendered pieces of the blocks that finished since along with the rendering of
// the block still growing, trimmed right the way a rendering ends. cacheTail
// says the text is complete, so the block still growing is the text's last and
// is kept in the piece cache. ok is false when the text cannot be told apart
// from one piece, and the caller has to render it whole.
func (g *growingMarkdown) grow(text string, width int, cacheTail bool) (finished []string, open string, ok bool) {
	if g.unsplit || !strings.HasPrefix(text, g.text[:g.scanned]) {
		return nil, "", false
	}
	if g.text == "" {
		// the first text sets the width, since nothing was rendered yet
		g.width = width
	} else if g.width != width {
		return nil, "", false
	}
	scan := blockScan{fence: g.fence, blank: g.blank, at: g.scanned}
	starts, ok := scan.seeks(text, g.blockStart, cacheTail)
	if !ok {
		g.unsplit = true
		return nil, "", false
	}
	for _, start := range starts {
		block := text[g.blockStart:start]
		piece, ok := markdownPiece(g.prev, block, width, true)
		if !ok {
			g.unsplit = true
			return nil, "", false
		}
		if !g.started {
			piece, g.started = strings.TrimLeft(piece, " \n"), true
		}
		finished = append(finished, piece)
		g.prev, g.blockStart = block, start
	}
	// the scan may stop short of a line still arriving
	g.text, g.scanned = text, scan.at
	g.fence, g.blank = scan.fence, scan.blank
	open, ok = markdownPiece(g.prev, text[g.blockStart:], width, cacheTail)
	if !ok {
		g.unsplit = true
		return nil, "", false
	}
	open = strings.TrimRight(open, " \n")
	if !g.started {
		open = strings.TrimLeft(open, " \n")
	}
	return finished, open, true
}

// blockScan is where splitting markdown text into top-level blocks stands: the
// fence open and whether the line last read was blank, at a position.
type blockScan struct {
	fence string
	blank bool
	at    int
}

// seeks reads text from the scan's position and returns where each new
// top-level block begins after the one open at start: the line at the margin
// after a blank line, outside a fence, that cannot continue a list or quote
// above it. whole says text is complete, so a last line still to come by its
// newline counts; a text still arriving is read only as far as its last
// newline, since half a line cannot be told from a whole one. ok is false when
// a line reaches across blank lines, which keeps the text whole.
func (s *blockScan) seeks(text string, start int, whole bool) (starts []int, ok bool) {
	limit := len(text)
	if !whole {
		limit = strings.LastIndexByte(text, '\n') + 1
	}
	for s.at < limit {
		i := strings.IndexByte(text[s.at:limit], '\n')
		end := limit
		if i >= 0 {
			end = s.at + i + 1
		}
		line := strings.TrimRight(text[s.at:end], "\r\n")
		if s.fence == "" && spansBlocks.MatchString(line) {
			return nil, false
		}
		if s.fence == "" && s.blank && s.at > start && opensBlock(line) {
			starts = append(starts, s.at)
			start = s.at
		}
		s.fence = fenceAfter(s.fence, line)
		s.blank = strings.TrimSpace(line) == ""
		s.at = end
	}
	return starts, true
}

// markdownPiece is what block adds to the rendering of prev, or false when
// rendering prev on its own does not begin the rendering of both. Only a
// finished block is kept: the last one may still be growing.
func markdownPiece(prev, block string, width int, finished bool) (string, bool) {
	key := pieceKey{width: width, prev: sha256.Sum256([]byte(prev)), block: block}
	if piece, ok := pieces.get(key); ok {
		return piece, true
	}
	whole, head := renderMarkdown(prev+block, width), ""
	if prev != "" {
		head, _ = markdownPiece("", prev, width, true)
	}
	if !strings.HasPrefix(whole, head) {
		return "", false
	}
	piece := whole[len(head):]
	if finished {
		pieces.put(key, piece)
	}
	return piece, true
}

// rendererKey is what a glamour renderer is built for.
type rendererKey struct {
	ink   ink
	width int
}

// renderers keeps the glamour renderer for the widths in use: building one
// costs more than most renders it does. A resize adds a width, so the map is
// emptied once it holds a handful.
var renderers = struct {
	sync.Mutex
	byKey map[rendererKey]*glamour.TermRenderer
}{byKey: map[rendererKey]*glamour.TermRenderer{}}

func markdownRenderer(width int) (*glamour.TermRenderer, error) {
	key := rendererKey{ink: transcriptInk, width: width}
	if renderer, ok := renderers.byKey[key]; ok {
		return renderer, nil
	}
	renderer, err := glamour.NewTermRenderer(
		glamour.WithStyles(markdownStyle()), glamour.WithWordWrap(width), glamour.WithPreservedNewLines(),
		mathOptions(accent(transcriptInk.math, "6")),
	)
	if err != nil {
		return nil, err
	}
	if len(renderers.byKey) >= 4 {
		clear(renderers.byKey)
	}
	renderers.byKey[key] = renderer
	return renderer, nil
}

func renderMarkdown(text string, width int) string {
	renderers.Lock()
	defer renderers.Unlock()
	renderer, err := markdownRenderer(width)
	if err != nil {
		return text
	}
	markdownThemes.Lock()
	defer markdownThemes.Unlock()
	rendered, err := renderer.Render(text)
	if err != nil {
		return text
	}
	return rendered
}

var (
	orderedItem = regexp.MustCompile(`^\d{1,9}[.)](\s|$)`)
	// Link definitions and raw HTML blocks can reach across blank lines.
	spansBlocks = regexp.MustCompile(`(?i)^ {0,3}(\[[^\]]+\]:|<(pre|script|style|textarea)\b|<!--)`)
)

// markdownBlocks is text split into the top-level blocks a rendering is built
// from, or text whole when it cannot be split.
func markdownBlocks(text string) []string {
	var scan blockScan
	starts, ok := scan.seeks(text, 0, true)
	if !ok {
		return []string{text}
	}
	blocks := make([]string, 0, len(starts)+1)
	from := 0
	for _, start := range starts {
		blocks = append(blocks, text[from:start])
		from = start
	}
	return append(blocks, text[from:])
}

func opensBlock(line string) bool {
	return line != "" && strings.IndexByte(" \t-*+>|", line[0]) < 0 && !orderedItem.MatchString(line)
}

// fenceAfter is the code fence or display math open after line, given the
// one open before. Display math is kept by its closer, $$ or \].
func fenceAfter(open, line string) string {
	if open == "$$" || open == `\]` {
		if strings.Contains(line, open) {
			return ""
		}
		return open
	}
	trimmed := strings.TrimLeft(line, " ")
	if len(line)-len(trimmed) > 3 || trimmed == "" {
		return open
	}
	if d, _, closed, ok := openDisplayMath([]byte(trimmed)); open == "" && ok && !closed {
		return d.close
	}
	if trimmed[0] != '`' && trimmed[0] != '~' {
		return open
	}
	run := trimmed[:len(trimmed)-len(strings.TrimLeft(trimmed, trimmed[:1]))]
	switch {
	case len(run) < 3:
		return open
	case open == "":
		return run
	case run[0] == open[0] && len(run) >= len(open) && strings.TrimSpace(trimmed[len(run):]) == "":
		return ""
	}
	return open
}

// pieceKey is what a rendered piece answers: the block it renders, at a width,
// after the block before it. That block is named by a digest of its text rather
// than by the text, because the text is already cached as the block it is: a
// key holding it would keep every block in a reply twice, once as itself and
// once as whatever the next block follows.
type pieceKey struct {
	prev  [sha256.Size]byte
	block string
	width int
}

// pieceCache keeps rendered pieces in two generations: a hit moves a piece
// into the fresh one, and the stale one is dropped once the fresh one fills,
// so the pieces the transcript still shows stay cached. Each generation holds
// at most maxPieceBytes of key and rendered text, excluding map overhead.
type pieceCache struct {
	fresh, stale map[pieceKey]string
	ink          ink
	bytes        int
	mu           sync.Mutex
}

const maxPieceBytes = 1 << 20

var pieces pieceCache

func (c *pieceCache) get(key pieceKey) (string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ink != transcriptInk {
		c.ink, c.fresh, c.stale, c.bytes = transcriptInk, nil, nil, 0
	}
	if piece, ok := c.fresh[key]; ok {
		return piece, true
	}
	piece, ok := c.stale[key]
	if ok {
		c.store(key, piece)
	}
	return piece, ok
}

// put keeps a copy of the block and the piece: they are slices of one moment's
// stream and its rendering, and would hold all of it.
func (c *pieceCache) put(key pieceKey, piece string) {
	if pieceKeySize(key, piece) > maxPieceBytes {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, exists := c.fresh[key]; exists {
		return
	}
	key.block = strings.Clone(key.block)
	c.store(key, strings.Clone(piece))
}

// pieceKeySize is what a cached piece adds to the cache, excluding map
// overhead.
func pieceKeySize(key pieceKey, piece string) int {
	return len(key.block) + len(piece) + sha256.Size
}

func (c *pieceCache) store(key pieceKey, piece string) {
	if _, exists := c.fresh[key]; exists {
		return
	}
	size := pieceKeySize(key, piece)
	if size > maxPieceBytes {
		return
	}
	if c.fresh == nil || size > maxPieceBytes-c.bytes {
		c.stale, c.fresh, c.bytes = c.fresh, map[pieceKey]string{}, 0
	}
	c.fresh[key] = piece
	c.bytes += size
}
