package tui

import (
	"regexp"
	"strings"

	"github.com/charmbracelet/x/ansi"
)

var (
	headerRegex = regexp.MustCompile(`^(#{1,6})\s+(.*)`)
	ulRegex     = regexp.MustCompile(`^(\s*)[*\-+]\s+(.*)`)
	olRegex     = regexp.MustCompile(`^(\s*)(\d+)\.\s+(.*)`)
	hrRegex     = regexp.MustCompile(`^(\*\*\*|---|___)$`)
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

// A bold lead before a colon or dash labels a list item, and a wholly bold
// item is a label too. Models bold nearly every item, and a signal on every
// line stops signalling, so these render plain.
var (
	boldLeadThenMark = regexp.MustCompile(`^\*\*([^*]+)\*\*(\s*(?::|—|–|\s-\s))`)
	boldLeadWithMark = regexp.MustCompile(`^\*\*([^*]+(?::|—|–))\*\*`)
	boldWhole        = regexp.MustCompile(`^\*\*([^*]+)\*\*\s*$`)
)

func plainLead(item string) string {
	switch {
	case boldWhole.MatchString(item):
		return boldWhole.ReplaceAllString(item, "$1")
	case boldLeadThenMark.MatchString(item):
		return boldLeadThenMark.ReplaceAllString(item, "$1$2")
	}
	return boldLeadWithMark.ReplaceAllString(item, "$1")
}

type emphasis struct{ strong, em, code bool }

// sgr restates the whole style after a full reset, so a closing span never
// strips an enclosing one and wrapOrChunkLine can reopen it on a later row.
func (e emphasis) sgr() string {
	s := ansiReset
	if e.code {
		s += inlineCodeInk()
	}
	if e.strong {
		s += ansiBold
	}
	if e.em {
		s += ansiItalic
	}
	return s
}

func inline(text string, base emphasis) string {
	var b strings.Builder
	strong, em := false, false
	style := func() emphasis { return emphasis{strong: base.strong || strong, em: base.em || em} }
	b.WriteString(base.sgr())
	for i := 0; i < len(text); {
		rest := text[i:]
		switch {
		case rest[0] == '`':
			if j := strings.IndexByte(rest[1:], '`'); j >= 0 {
				code := style()
				code.code = true
				// dim ticks mark the edges and pad the tint, and copied text keeps its markdown
				tick := decorInk() + "`"
				b.WriteString(code.sgr() + tick + code.sgr() + rest[1:1+j] + tick + style().sgr())
				i += j + 2
				continue
			}
		case strings.HasPrefix(rest, "**"):
			if strong || strings.Contains(rest[2:], "**") {
				strong = !strong
				b.WriteString(style().sgr())
				i += 2
				continue
			}
		case rest[0] == '*':
			opens := !em && len(rest) > 1 && rest[1] != ' ' && strings.Contains(rest[2:], "*")
			closes := em && text[i-1] != ' '
			if opens || closes {
				em = opens
				b.WriteString(style().sgr())
				i++
				continue
			}
		}
		b.WriteByte(rest[0])
		i++
	}
	return b.String() + ansiReset
}

func RenderInlineMarkdown(text string) string {
	return inline(text, emphasis{})
}

func RenderMarkdownAnsi(text string, width int) string {
	if width <= 0 {
		width = 80
	}
	mark := func(s string) string { return decorInk() + s + ansiReset }
	// hang wraps body under its lead so continuation rows keep the list,
	// quote, or code gutter instead of falling back to column zero.
	hang := func(lead, cont, body string) []string {
		rows := wrapOrChunkLine(body, max(1, width-ansi.StringWidth(lead)))
		for i := range rows {
			if i == 0 {
				rows[i] = lead + rows[i]
			} else {
				rows[i] = cont + rows[i]
			}
		}
		return rows
	}
	lines := strings.Split(text, "\n")
	var out []string
	for i := 0; i < len(lines); i++ {
		line := lines[i]
		if strings.HasPrefix(line, "```") {
			lang := strings.TrimSpace(strings.TrimPrefix(line, "```"))
			start := i + 1
			for i = start; i < len(lines) && !strings.HasPrefix(lines[i], "```"); i++ {
			}
			code := strings.Join(lines[start:min(i, len(lines))], "\n")
			if lang != "" {
				out = append(out, mark("┌─ "+lang))
			}
			for _, hl := range strings.Split(HighlightCode(code, lang), "\n") {
				out = append(out, hang(mark("│")+" ", mark("│")+" ", codeInk()+hl+ansiReset)...)
			}
			out = append(out, mark("└"))
			continue
		}
		if h := headerRegex.FindStringSubmatch(line); h != nil {
			out = append(out, inline(h[2], emphasis{strong: true}))
			continue
		}
		if hrRegex.MatchString(strings.TrimSpace(line)) {
			out = append(out, mark(strings.Repeat("─", width)))
			continue
		}
		if ul := ulRegex.FindStringSubmatch(line); ul != nil {
			out = append(out, hang(ul[1]+mark("•")+" ", ul[1]+"  ", inline(plainLead(ul[2]), emphasis{}))...)
			continue
		}
		if ol := olRegex.FindStringSubmatch(line); ol != nil {
			lead := ol[1] + ol[2] + ". "
			out = append(out, hang(ol[1]+mark(ol[2]+".")+" ", strings.Repeat(" ", len(lead)), inline(plainLead(ol[3]), emphasis{}))...)
			continue
		}
		if quote, ok := strings.CutPrefix(line, "> "); ok {
			out = append(out, hang(mark("│")+" ", mark("│")+" ", inline(quote, emphasis{}))...)
			continue
		}
		if line == "" {
			out = append(out, "")
			continue
		}
		out = append(out, inline(line, emphasis{}))
	}
	return strings.Join(out, "\n")
}
