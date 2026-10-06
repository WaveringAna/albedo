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
	chromastyles "github.com/alecthomas/chroma/v2/styles"
)

// hashComments are the languages whose line comments start with "#".
var hashComments = wordSet(
	"python", "py", "sh", "bash", "zsh", "shell", "nu",
	"nix", "toml", "yaml", "yml", "ruby", "rb", "elixir",
)

// HighlightCode marks only comments. Every other token keeps the code's own
// ink: highlighting has shown little measured benefit for comprehension, and
// a hue per token class drowns the few hues that carry meaning here.
// Comments stay readable because they are the notes in the code.
func HighlightCode(code string, lang string) string {
	l := strings.ToLower(lang)
	if l == "" || l == "text" || l == "plain" || l == "txt" {
		return code
	}
	hash := hashComments[l]
	comment := faintInk() + ansiItalic
	var b strings.Builder
	chars := []rune(code)
	for i := 0; i < len(chars); {
		ch := chars[i]
		if (hash && ch == '#') || (!hash && ch == '/' && i+1 < len(chars) && chars[i+1] == '/') {
			j := i
			for j < len(chars) && chars[j] != '\n' {
				j++
			}
			b.WriteString(comment)
			b.WriteString(string(chars[i:j]))
			b.WriteString(ansiReset)
			b.WriteString(codeInk())
			i = j
			continue
		}
		if ch == '"' || ch == '\'' || ch == '`' {
			j := i + 1
			for j < len(chars) && chars[j] != ch && chars[j] != '\n' {
				if chars[j] == '\\' {
					j++
				}
				j++
			}
			j = min(j+1, len(chars))
			b.WriteString(string(chars[i:j]))
			i = j
			continue
		}
		b.WriteRune(ch)
		i++
	}
	return b.String()
}

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

// Chroma themes are registered by name; key them by the detected terminal
// palette so a theme change cannot reuse the previous palette's colors.
func codeTheme(colors ink) string {
	if colors.code == "" {
		return "monokai"
	}
	palette := colors.code + colors.secondary + colors.brandFrom + colors.brandTo
	hash := sha256.Sum256([]byte(palette))
	name := fmt.Sprintf("albedo-%x", hash[:6])
	markdownThemes.Lock()
	defer markdownThemes.Unlock()
	if chromastyles.Registry[name] == nil {
		chromastyles.Register(chroma.MustNewStyle(name, chroma.StyleEntries{
			chroma.Text:          colors.code,
			chroma.Comment:       colors.secondary + " italic",
			chroma.Keyword:       colors.brandFrom,
			chroma.NameFunction:  colors.brandTo,
			chroma.LiteralString: colors.brandTo,
			chroma.LiteralNumber: colors.brandFrom,
		}))
	}
	return name
}

func markdownStyle() ansi.StyleConfig {
	style := styles.NoTTYStyleConfig
	zero, bold := uint(0), true
	style.Document.Margin = &zero
	style.Document.BlockPrefix, style.Document.BlockSuffix = "", ""
	style.Heading.BlockSuffix = ""
	for _, heading := range []*ansi.StyleBlock{&style.H1, &style.H2, &style.H3, &style.H4, &style.H5, &style.H6} {
		heading.Prefix = ""
		heading.Bold = &bold
	}
	style.Strong = ansi.StylePrimitive{Bold: &bold}
	style.Emph = ansi.StylePrimitive{Italic: &bold}
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
	blocks := markdownBlocks(text)
	var b strings.Builder
	for i, block := range blocks {
		prev := ""
		if i > 0 {
			prev = blocks[i-1]
		}
		piece, ok := markdownPiece(prev, block, width, whole || i < len(blocks)-1)
		if !ok {
			return strings.Trim(renderMarkdown(text, width), " \n")
		}
		b.WriteString(piece)
	}
	return strings.Trim(b.String(), " \n")
}

// markdownPiece is what block adds to the rendering of prev, or false when
// rendering prev on its own does not begin the rendering of both. Only a
// finished block is kept: the last one may still be growing.
func markdownPiece(prev, block string, width int, finished bool) (string, bool) {
	key := pieceKey{width: width, prev: prev, block: block}
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

func renderMarkdown(text string, width int) string {
	renderer, err := glamour.NewTermRenderer(
		glamour.WithStyles(markdownStyle()), glamour.WithWordWrap(width), glamour.WithPreservedNewLines(),
	)
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

// markdownBlocks splits text before every line that has to open a new
// top-level block: one at the margin after a blank line, outside a fence,
// that cannot continue a list or quote above it. Text that can reach across
// blank lines outside a fence keeps it whole.
func markdownBlocks(text string) []string {
	var blocks []string
	start, fence, blank := 0, "", false
	for pos := 0; pos < len(text); {
		i := strings.IndexByte(text[pos:], '\n')
		end := len(text)
		if i >= 0 {
			end = pos + i + 1
		}
		line := strings.TrimRight(text[pos:end], "\r\n")
		if fence == "" && spansBlocks.MatchString(line) {
			return []string{text}
		}
		if fence == "" && blank && pos > start && opensBlock(line) {
			blocks = append(blocks, text[start:pos])
			start = pos
		}
		fence = fenceAfter(fence, line)
		blank = strings.TrimSpace(line) == ""
		pos = end
	}
	return append(blocks, text[start:])
}

func opensBlock(line string) bool {
	return line != "" && strings.IndexByte(" \t-*+>|", line[0]) < 0 && !orderedItem.MatchString(line)
}

// fenceAfter is the code fence open after line, given the one open before.
func fenceAfter(open, line string) string {
	trimmed := strings.TrimLeft(line, " ")
	if len(line)-len(trimmed) > 3 || trimmed == "" || (trimmed[0] != '`' && trimmed[0] != '~') {
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

type pieceKey struct {
	prev, block string
	width       int
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

// put keeps copies: the key and piece are slices of one moment's stream and
// its rendering, and would hold all of it.
func (c *pieceCache) put(key pieceKey, piece string) {
	if len(key.prev)+len(key.block)+len(piece) > maxPieceBytes {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, exists := c.fresh[key]; exists {
		return
	}
	key.prev, key.block = strings.Clone(key.prev), strings.Clone(key.block)
	c.store(key, strings.Clone(piece))
}

func (c *pieceCache) store(key pieceKey, piece string) {
	if _, exists := c.fresh[key]; exists {
		return
	}
	size := len(key.prev) + len(key.block) + len(piece)
	if size > maxPieceBytes {
		return
	}
	if c.fresh == nil || size > maxPieceBytes-c.bytes {
		c.stale, c.fresh, c.bytes = c.fresh, map[pieceKey]string{}, 0
	}
	c.fresh[key] = piece
	c.bytes += size
}
