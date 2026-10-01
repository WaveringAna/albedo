package daemon

import (
	"regexp"
	"strings"
)

var (
	whitespaceRegex = regexp.MustCompile(`\s+`)
	assignStrRegex  = regexp.MustCompile(`^([a-zA-Z_]\w*)\s*=\s*[rR]?['"]([^'"]*)['"]`)
	assignPathRegex = regexp.MustCompile(`^([a-zA-Z_]\w*)\s*=\s*(?:pathlib\.)?Path\(\s*[rR]?['"]([^'"]*)['"]\s*\)`)
	pathMethodRegex = regexp.MustCompile(`(?:(?:pathlib\.)?Path\(\s*[rR]?['"]([^'"]*)['"]\s*\)|([a-zA-Z_]\w*))\.(write_text|write_bytes|read_text|read_bytes|open)\(\s*([^)]*)\)`)
	funcCallRegex   = regexp.MustCompile(`\b(edit|read|open)\(\s*([^)]*)\)`)
	// run(program, *args) and rem.run(...), but not cells.run(id)
	runCallRegex    = regexp.MustCompile(`(?:^|[^.\w]|\brem\.)run\(([^)]*)`)
	runWordRegex    = regexp.MustCompile(`^\s*[rR]?['"]([^'"]*)['"]\s*(?:,|$)`)
	argExtractRegex = regexp.MustCompile(`(?:(?:path|file)\s*=\s*)?(?:[rR]?['"]([^'"]*)['"]|([a-zA-Z_]\w*))`)
	modeRegex       = regexp.MustCompile(`['"]([rwaxbt+]+)['"]`)
)

func cleanLabel(s string) string {
	s = sanitizeControlRunes(s)
	s = whitespaceRegex.ReplaceAllString(s, " ")
	s = strings.TrimSpace(s)
	if len(s) > 300 {
		return s[:300]
	}
	return s
}

func ParsePythonIntent(code string) *ToolIntent {
	bindings := make(map[string]string)
	var intents []ToolIntent

	for rawLine := range strings.SplitSeq(code, "\n") {
		line := strings.TrimSpace(rawLine)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		if m := assignStrRegex.FindStringSubmatch(line); m != nil {
			bindings[m[1]] = m[2]
			continue
		}

		if m := assignPathRegex.FindStringSubmatch(line); m != nil {
			bindings[m[1]] = m[2]
			continue
		}

		if m := pathMethodRegex.FindStringSubmatch(line); m != nil {
			pathLiteral := m[1]
			pathVariable := m[2]
			method := m[3]
			args := m[4]

			target := pathLiteral
			if target == "" && pathVariable != "" {
				target = bindings[pathVariable]
			}

			if target != "" {
				label := cleanLabel(target)
				switch method {
				case "write_text", "write_bytes":
					intents = append(intents, ToolIntent{Kind: "write", Target: label})
				case "read_text", "read_bytes":
					intents = append(intents, ToolIntent{Kind: "read", Target: label})
				case "open":
					mode := "r"
					if mm := modeRegex.FindStringSubmatch(args); mm != nil {
						mode = mm[1]
					}
					kind := "read"
					if strings.ContainsAny(mode, "wax+") {
						kind = "write"
					}
					intents = append(intents, ToolIntent{Kind: kind, Target: label})
				}
				continue
			}
		}

		if m := runCallRegex.FindStringSubmatch(line); m != nil {
			if words := runWords(m[1]); len(words) > 0 {
				intents = append(intents, ToolIntent{Kind: "run", Target: cleanLabel(strings.Join(words, " "))})
				continue
			}
		}

		if m := funcCallRegex.FindStringSubmatch(line); m != nil {
			functionName := m[1]
			args := m[2]

			if am := argExtractRegex.FindStringSubmatch(args); am != nil {
				literalValue := am[1]
				variableName := am[2]
				target := literalValue
				if target == "" && variableName != "" {
					target = bindings[variableName]
				}

				if target != "" {
					label := cleanLabel(target)
					switch functionName {
					case "edit":
						intents = append(intents, ToolIntent{Kind: "edit", Target: label})
					case "read":
						intents = append(intents, ToolIntent{Kind: "read", Target: label})
					case "open":
						mode := "r"
						if mm := modeRegex.FindStringSubmatch(args); mm != nil {
							mode = mm[1]
						}
						kind := "read"
						if strings.ContainsAny(mode, "wax+") {
							kind = "write"
						}
						intents = append(intents, ToolIntent{Kind: kind, Target: label})
					}
				}
			}
		}
	}

	if len(intents) == 0 {
		return nil
	}
	return &intents[len(intents)-1]
}

// runWords is the leading string literals of run()'s arguments: the program
// and its arguments, up to the first expression or keyword.
func runWords(args string) []string {
	var words []string
	for {
		m := runWordRegex.FindStringSubmatchIndex(args)
		if m == nil {
			return words
		}
		words = append(words, args[m[2]:m[3]])
		args = args[m[1]:]
	}
}

func ExtractPartialJSONCode(s string) string {
	codeKeyIndex := strings.Index(s, `"code"`)
	if codeKeyIndex == -1 {
		return ""
	}
	colon := strings.Index(s[codeKeyIndex+6:], ":")
	if colon == -1 {
		return ""
	}
	colon += codeKeyIndex + 6

	quote := strings.Index(s[colon+1:], `"`)
	if quote == -1 {
		return ""
	}
	start := colon + 1 + quote + 1

	var decodedCode strings.Builder
	var decoder JSONStringDecoder
	decoder.Append(s[start:], func(text string) { decodedCode.WriteString(text) })
	return decodedCode.String()
}

type ToolCallAssembly struct {
	ID       string
	Function struct {
		Name      string
		Arguments string
	}
}

type ToolProgressReporter struct {
	publish  func(*ToolProgress) error
	previous *ToolProgress
	raw      string
	code     string
}

func NewToolProgressReporter(publish func(*ToolProgress) error) *ToolProgressReporter {
	return &ToolProgressReporter{
		publish: publish,
	}
}

func (r *ToolProgressReporter) Reset() {
	r.raw = ""
	r.code = ""
}

func (r *ToolProgressReporter) Report(call *ToolCallAssembly, phase string) error {
	if call == nil {
		if r.previous != nil {
			err := r.publish(nil)
			r.previous = nil
			r.Reset()
			return err
		}
		r.Reset()
		return nil
	}

	name := cleanLabel(call.Function.Name)
	if len(name) > 100 {
		name = name[:100]
	}
	if name == "" {
		return nil
	}

	callID := call.ID
	if len(callID) > 200 {
		callID = callID[:200]
	}

	args := call.Function.Arguments
	sameCall := r.previous != nil && r.previous.CallID == callID && r.previous.Name == name
	continued := sameCall && strings.HasPrefix(args, r.raw)

	if !continued {
		r.Reset()
	}

	if name == "python" && len(args) > len(r.raw) {
		r.code = ExtractPartialJSONCode(args)
		r.raw = args
	}

	var intent *ToolIntent
	if continued && r.previous != nil {
		intent = r.previous.Intent
	}
	if parsed := ParsePythonIntent(r.code); parsed != nil {
		intent = parsed
	}

	var preview *ToolCodePreview
	if phase == "generating" && len(r.code) > 0 {
		codeRunes := []rune(r.code)
		offset := max(0, len(codeRunes)-512)
		text := sanitizeControlRunes(string(codeRunes[offset:]))
		preview = &ToolCodePreview{
			Offset: offset,
			Text:   text,
		}
	}

	next := &ToolProgress{
		CallID: callID,
		Name:   name,
		Phase:  phase,
		Intent: intent,
		Code:   preview,
	}

	if !toolProgressEqual(next, r.previous) {
		if err := r.publish(next); err != nil {
			return err
		}
		r.previous = next
	}
	return nil
}

func toolProgressEqual(a, b *ToolProgress) bool {
	if a == nil && b == nil {
		return true
	}
	if a == nil || b == nil {
		return false
	}
	if a.CallID != b.CallID || a.Name != b.Name || a.Phase != b.Phase {
		return false
	}
	if (a.Intent == nil) != (b.Intent == nil) {
		return false
	}
	if a.Intent != nil && *a.Intent != *b.Intent {
		return false
	}
	if (a.Code == nil) != (b.Code == nil) {
		return false
	}
	if a.Code != nil && *a.Code != *b.Code {
		return false
	}
	return true
}
