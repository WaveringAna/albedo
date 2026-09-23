package daemon

import (
	"math"
	"regexp"
	"strconv"
	"strings"
)

var (
	whitespaceRegex = regexp.MustCompile(`\s+`)
	assignStrRegex  = regexp.MustCompile(`^([a-zA-Z_]\w*)\s*=\s*[rR]?['"]([^'"]*)['"]`)
	assignPathRegex = regexp.MustCompile(`^([a-zA-Z_]\w*)\s*=\s*(?:pathlib\.)?Path\(\s*[rR]?['"]([^'"]*)['"]\s*\)`)
	pathMethodRegex = regexp.MustCompile(`(?:(?:pathlib\.)?Path\(\s*[rR]?['"]([^'"]*)['"]\s*\)|([a-zA-Z_]\w*))\.(write_text|write_bytes|read_text|read_bytes|open)\(\s*([^)]*)\)`)
	funcCallRegex   = regexp.MustCompile(`\b(edit|read|sh|open)\(\s*([^)]*)\)`)
	argExtractRegex = regexp.MustCompile(`(?:(?:path|file|command)\s*=\s*)?(?:[rR]?['"]([^'"]*)['"]|([a-zA-Z_]\w*))`)
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

	lines := strings.Split(code, "\n")
	for _, rawLine := range lines {
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
			pLit := m[1]
			pVar := m[2]
			method := m[3]
			args := m[4]

			target := pLit
			if target == "" && pVar != "" {
				target = bindings[pVar]
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

		if m := funcCallRegex.FindStringSubmatch(line); m != nil {
			fnName := m[1]
			args := m[2]

			if am := argExtractRegex.FindStringSubmatch(args); am != nil {
				litVal := am[1]
				varVal := am[2]
				target := litVal
				if target == "" && varVal != "" {
					target = bindings[varVal]
				}

				if target != "" {
					label := cleanLabel(target)
					switch fnName {
					case "edit":
						intents = append(intents, ToolIntent{Kind: "edit", Target: label})
					case "read":
						intents = append(intents, ToolIntent{Kind: "read", Target: label})
					case "sh":
						intents = append(intents, ToolIntent{Kind: "run", Target: label})
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

func ExtractPartialJSONCode(s string) string {
	idx := strings.Index(s, `"code"`)
	if idx == -1 {
		return ""
	}
	colon := strings.Index(s[idx+6:], ":")
	if colon == -1 {
		return ""
	}
	colon += idx + 6

	quote := strings.Index(s[colon+1:], `"`)
	if quote == -1 {
		return ""
	}
	start := colon + 1 + quote + 1

	var sb strings.Builder
	bytes := []byte(s[start:])
	i := 0
	for i < len(bytes) {
		b := bytes[i]
		if b == '"' {
			break
		}
		if b == '\\' {
			if i+1 >= len(bytes) {
				break
			}
			nxt := bytes[i+1]
			switch nxt {
			case 'n':
				sb.WriteByte('\n')
				i += 2
			case 'r':
				sb.WriteByte('\r')
				i += 2
			case 't':
				sb.WriteByte('\t')
				i += 2
			case '"':
				sb.WriteByte('"')
				i += 2
			case '\\':
				sb.WriteByte('\\')
				i += 2
			case 'u':
				if i+5 < len(bytes) {
					hexVal := string(bytes[i+2 : i+6])
					if cp, err := strconv.ParseInt(hexVal, 16, 32); err == nil {
						sb.WriteRune(rune(cp))
						i += 6
						continue
					}
				}
				sb.WriteByte(nxt)
				i += 2
			default:
				sb.WriteByte(nxt)
				i += 2
			}
		} else {
			sb.WriteByte(b)
			i++
		}
	}
	return sb.String()
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
		offset := int(math.Max(0, float64(len(codeRunes)-512)))
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
