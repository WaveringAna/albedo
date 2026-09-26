package tui

import (
	"crypto/sha256"
	"fmt"
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

func RenderMarkdownAnsi(text string, width int) string {
	if width <= 0 {
		width = 80
	}
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
	return strings.Trim(rendered, " \n")
}
