package tui

import (
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
var hashComments = map[string]bool{
	"python": true, "py": true, "sh": true, "bash": true, "zsh": true, "shell": true, "nu": true,
	"nix": true, "toml": true, "yaml": true, "yml": true, "ruby": true, "rb": true, "elixir": true,
}

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
			b.WriteString(comment + string(chars[i:j]) + ansiReset + codeInk())
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
	zero := uint(0)
	bold := true
	style.Document.Margin = &zero
	style.Document.BlockPrefix = ""
	style.Document.BlockSuffix = ""
	style.Heading.BlockSuffix = ""
	for _, heading := range []*ansi.StyleBlock{&style.H1, &style.H2, &style.H3, &style.H4, &style.H5, &style.H6} {
		heading.Prefix = ""
		heading.Bold = &bold
	}
	style.Strong = ansi.StylePrimitive{Bold: &bold}
	style.Emph = ansi.StylePrimitive{Italic: &bold}
	style.Table.Margin = &zero
	style.BlockQuote.IndentToken = new(decorInk() + "│ " + ansiReset)
	style.CodeBlock.Margin = &zero
	style.CodeBlock.BlockPrefix = decorInk() + "┌─" + ansiReset + "\n"
	style.CodeBlock.BlockSuffix = decorInk() + "└" + ansiReset
	style.HorizontalRule.Format = "\n────────────\n"
	if transcriptInk.decor != "" {
		style.HorizontalRule.Color = &transcriptInk.decor
	}
	style.CodeBlock.Theme = codeTheme(transcriptInk)
	return style
}

// RenderMarkdownAnsi renders text block by block. Glamour spaces a block by
// the one before it and no further, so a finished block renders once and a
// reply streaming in re-renders only its last block.
func RenderMarkdownAnsi(text string, width int) string {
	if width <= 0 {
		width = 80
	}
	blocks := markdownBlocks(text)
	var b strings.Builder
	for i, block := range blocks {
		prev := ""
		if i > 0 {
			prev = blocks[i-1]
		}
		piece, ok := markdownPiece(prev, block, width, i < len(blocks)-1)
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
	key := pieceKey{width, prev, block}
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
	rendered, err := renderer.Render(text)
	markdownThemes.Unlock()
	if err != nil {
		return text
	}
	return rendered
}

var (
	orderedItem = regexp.MustCompile(`^\d{1,9}[.)](\s|$)`)
	// Link definitions and raw HTML blocks can reach across blank lines.
	spansBlocks = regexp.MustCompile(`(?im)^ {0,3}(\[[^\]]+\]:|<(pre|script|style|textarea)\b|<!--)`)
)

// markdownBlocks splits text before every line that has to open a new
// top-level block: one at the margin after a blank line, outside a fence,
// that cannot continue a list or quote above it.
func markdownBlocks(text string) []string {
	if spansBlocks.MatchString(text) {
		return []string{text}
	}
	var blocks []string
	start, fence, blank := 0, "", false
	for pos := 0; pos < len(text); {
		end := len(text)
		if i := strings.IndexByte(text[pos:], '\n'); i >= 0 {
			end = pos + i + 1
		}
		line := strings.TrimRight(text[pos:end], "\r\n")
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
	return line != "" && !strings.ContainsRune(" \t-*+>|", rune(line[0])) && !orderedItem.MatchString(line)
}

// fenceAfter is the code fence open after line, given the one open before.
func fenceAfter(open, line string) string {
	trimmed := strings.TrimLeft(line, " ")
	if len(line)-len(trimmed) > 3 || trimmed == "" || trimmed[0] != '`' && trimmed[0] != '~' {
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
	width       int
	prev, block string
}

// pieceCache keeps rendered pieces in two generations: a hit moves a piece
// into the fresh one, and the stale one is dropped once the fresh one fills,
// so the pieces the transcript still shows stay cached.
type pieceCache struct {
	mu           sync.Mutex
	ink          ink
	fresh, stale map[pieceKey]string
	bytes        int
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

func (c *pieceCache) put(key pieceKey, piece string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.store(key, piece)
}

func (c *pieceCache) store(key pieceKey, piece string) {
	if c.fresh == nil || c.bytes > maxPieceBytes {
		c.stale, c.fresh, c.bytes = c.fresh, map[pieceKey]string{}, 0
	}
	c.fresh[key] = piece
	c.bytes += len(key.prev) + len(key.block) + len(piece)
}
