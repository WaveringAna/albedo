package tui

import (
	"regexp"
	"strings"
	"unicode"
)

var (
	headerRegex = regexp.MustCompile(`^(#{1,6})\s+(.*)`)
	ulRegex     = regexp.MustCompile(`^(\s*)[*\-+]\s+(.*)`)
	olRegex     = regexp.MustCompile(`^(\s*)(\d+)\.\s+(.*)`)
	hrRegex     = regexp.MustCompile(`^(\*\*\*|---|___)$`)

	kwPy = map[string]bool{
		"if": true, "elif": true, "else": true, "for": true, "while": true, "in": true, "not": true, "and": true,
		"or": true, "is": true, "import": true, "from": true, "as": true, "def": true, "class": true, "return": true,
		"yield": true, "pass": true, "break": true, "continue": true, "try": true, "except": true, "finally": true,
		"raise": true, "with": true, "lambda": true, "True": true, "False": true, "None": true, "async": true, "await": true,
	}

	kwJS = map[string]bool{
		"if": true, "else": true, "for": true, "while": true, "do": true, "switch": true, "case": true, "break": true,
		"continue": true, "return": true, "function": true, "class": true, "const": true, "let": true, "var": true,
		"new": true, "import": true, "export": true, "default": true, "from": true, "async": true, "await": true,
		"try": true, "catch": true, "finally": true, "throw": true, "null": true, "undefined": true, "true": true, "false": true,
	}

	kwGo = map[string]bool{
		"break": true, "default": true, "func": true, "interface": true, "select": true, "case": true, "defer": true,
		"go": true, "map": true, "struct": true, "chan": true, "else": true, "goto": true, "package": true,
		"switch": true, "const": true, "fallthrough": true, "if": true, "range": true, "type": true, "continue": true,
		"for": true, "import": true, "return": true, "var": true, "nil": true, "true": true, "false": true,
	}
)

const (
	ansiReset    = "\x1b[0m"
	ansiBold     = "\x1b[1m"
	ansiDim      = "\x1b[2m"
	ansiItalic   = "\x1b[3m"
	ansiGreen    = "\x1b[32m"
	ansiCyan     = "\x1b[36m"
	ansiGray     = "\x1b[90m"
	ansiBYellow  = "\x1b[93m"
	ansiBBlue    = "\x1b[94m"
	ansiBMagenta = "\x1b[95m"
	ansiBCyan    = "\x1b[96m"
)

func getKeywords(lang string) map[string]bool {
	switch strings.ToLower(lang) {
	case "python", "py":
		return kwPy
	default:
		return kwJS
	}
}

func HighlightCode(code string, lang string) string {
	l := strings.ToLower(lang)
	if l == "" || l == "text" || l == "plain" || l == "txt" {
		return code
	}
	keywords := getKeywords(l)
	isPy := l == "python" || l == "py"

	var b strings.Builder
	chars := []rune(code)
	n := len(chars)
	i := 0

	for i < n {
		ch := chars[i]

		// Single line comments
		if (!isPy && ch == '/' && i+1 < n && chars[i+1] == '/') || (isPy && ch == '#') {
			j := i
			for j < n && chars[j] != '\n' {
				j++
			}
			b.WriteString(ansiGray + ansiItalic)
			b.WriteString(string(chars[i:j]))
			b.WriteString(ansiReset)
			i = j
			continue
		}

		// Strings
		if ch == '"' || ch == '\'' || ch == '`' {
			quote := ch
			j := i + 1
			for j < n {
				if chars[j] == '\\' && j+1 < n {
					j += 2
					continue
				}
				if chars[j] == quote {
					j++
					break
				}
				j++
			}
			b.WriteString(ansiGreen)
			b.WriteString(string(chars[i:j]))
			b.WriteString(ansiReset)
			i = j
			continue
		}

		// Numbers
		if unicode.IsDigit(ch) && (i == 0 || !unicode.IsLetter(chars[i-1])) {
			j := i
			for j < n && (unicode.IsDigit(chars[j]) || chars[j] == '.' || chars[j] == '_' || chars[j] == 'x' || chars[j] == 'b') {
				j++
			}
			b.WriteString(ansiBYellow)
			b.WriteString(string(chars[i:j]))
			b.WriteString(ansiReset)
			i = j
			continue
		}

		// Identifiers / keywords
		if unicode.IsLetter(ch) || ch == '_' {
			j := i
			for j < n && (unicode.IsLetter(chars[j]) || unicode.IsDigit(chars[j]) || chars[j] == '_') {
				j++
			}
			word := string(chars[i:j])
			if keywords[word] {
				b.WriteString(ansiBMagenta + word + ansiReset)
			} else if unicode.IsUpper(chars[i]) {
				b.WriteString(ansiBYellow + word + ansiReset)
			} else if j < n && chars[j] == '(' {
				b.WriteString(ansiBBlue + word + ansiReset)
			} else {
				b.WriteString(word)
			}
			i = j
			continue
		}

		b.WriteRune(ch)
		i++
	}

	return b.String()
}

func RenderInlineMarkdown(text string) string {
	// Inline code: `code`
	res := text
	for {
		start := strings.Index(res, "`")
		if start == -1 {
			break
		}
		end := strings.Index(res[start+1:], "`")
		if end == -1 {
			break
		}
		end += start + 1
		code := res[start+1 : end]
		res = res[:start] + ansiCyan + code + ansiReset + res[end+1:]
	}

	// Bold: **text**
	for {
		start := strings.Index(res, "**")
		if start == -1 {
			break
		}
		end := strings.Index(res[start+2:], "**")
		if end == -1 {
			break
		}
		end += start + 2
		content := res[start+2 : end]
		res = res[:start] + ansiBold + content + ansiReset + res[end+2:]
	}

	// Italic: *text*
	for {
		start := strings.Index(res, "*")
		if start == -1 {
			break
		}
		end := strings.Index(res[start+1:], "*")
		if end == -1 {
			break
		}
		end += start + 1
		content := res[start+1 : end]
		res = res[:start] + ansiItalic + content + ansiReset + res[end+1:]
	}

	return res
}

func RenderMarkdownAnsi(text string, width int) string {
	if width <= 0 {
		width = 80
	}
	lines := strings.Split(text, "\n")
	var out []string
	i := 0

	for i < len(lines) {
		line := lines[i]

		// Fenced code block
		if strings.HasPrefix(line, "```") {
			lang := strings.TrimSpace(strings.TrimPrefix(line, "```"))
			var codeLines []string
			i++
			for i < len(lines) && !strings.HasPrefix(lines[i], "```") {
				codeLines = append(codeLines, lines[i])
				i++
			}
			if i < len(lines) {
				i++
			}

			code := strings.Join(codeLines, "\n")
			highlighted := HighlightCode(code, lang)

			if lang != "" {
				out = append(out, ansiDim+ansiCyan+"┌─ "+lang+ansiReset)
			}
			for _, hl := range strings.Split(highlighted, "\n") {
				out = append(out, ansiDim+"│"+ansiReset+" "+hl)
			}
			out = append(out, ansiDim+"└"+ansiReset)
			continue
		}

		// Headers
		if hMatch := headerRegex.FindStringSubmatch(line); hMatch != nil {
			title := RenderInlineMarkdown(hMatch[2])
			colors := []string{ansiBCyan, ansiCyan, ansiBBlue, ansiBBlue, ansiBMagenta, ansiBMagenta}
			out = append(out, ansiBold+colors[len(hMatch[1])-1]+title+ansiReset)
			i++
			continue
		}

		// Horizontal rule
		if hrRegex.MatchString(strings.TrimSpace(line)) {
			barLen := width
			out = append(out, ansiDim+strings.Repeat("─", barLen)+ansiReset)
			i++
			continue
		}

		// Bullet list
		if ulMatch := ulRegex.FindStringSubmatch(line); ulMatch != nil {
			indent := ulMatch[1]
			item := RenderInlineMarkdown(ulMatch[2])
			out = append(out, indent+ansiDim+"•"+ansiReset+" "+item)
			i++
			continue
		}

		// Numbered list
		if olMatch := olRegex.FindStringSubmatch(line); olMatch != nil {
			indent := olMatch[1]
			num := olMatch[2]
			item := RenderInlineMarkdown(olMatch[3])
			out = append(out, indent+ansiDim+num+"."+ansiReset+" "+item)
			i++
			continue
		}

		// Blockquote
		if strings.HasPrefix(line, "> ") {
			quote := RenderInlineMarkdown(strings.TrimPrefix(line, "> "))
			out = append(out, ansiDim+"│"+ansiReset+" "+ansiItalic+quote+ansiReset)
			i++
			continue
		}

		out = append(out, RenderInlineMarkdown(line))
		i++
	}

	return strings.Join(out, "\n")
}
