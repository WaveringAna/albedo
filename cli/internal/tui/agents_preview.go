package tui

import (
	"iter"
	"strings"
	"unicode/utf8"
)

const (
	agentPreviewBytes = 64 << 10
	agentPreviewLines = 120
)

type agentTailSpan struct {
	start, end uint64
	kind       tailKind
}

// agentTail owns its bytes. Absolute offsets let a long line lose its oldest
// bytes without shifting the window or retaining the original stream chunks.
type agentTail struct {
	data    []byte
	lines   [agentPreviewLines]agentTailSpan
	end     uint64
	head    int
	count   int
	open    bool
	omitted bool
}

func (tail *agentTail) dropOldest() {
	tail.lines[tail.head] = agentTailSpan{}
	tail.head = (tail.head + 1) % agentPreviewLines
	tail.count--
	tail.omitted = true
}

func (tail *agentTail) begin(kind tailKind) {
	if tail.count == agentPreviewLines {
		tail.dropOldest()
	}
	index := (tail.head + tail.count) % agentPreviewLines
	tail.lines[index] = agentTailSpan{start: tail.end, end: tail.end, kind: kind}
	tail.count++
	tail.open = true
}

func (tail *agentTail) grow(extra int) {
	start := tail.lines[tail.head].start
	retained := int(tail.end - start)
	required := min(agentPreviewBytes, retained+extra)
	if required <= len(tail.data) {
		return
	}
	data := make([]byte, min(agentPreviewBytes, max(64, required, len(tail.data)*2)))
	if retained > 0 {
		index := int(start % uint64(len(tail.data)))
		copied := copy(data[:retained], tail.data[index:])
		copy(data[copied:retained], tail.data[:retained-copied])
	}
	for offset := range tail.count {
		span := &tail.lines[(tail.head+offset)%agentPreviewLines]
		span.start -= start
		span.end -= start
	}
	tail.end -= start
	tail.data = data
}

func (tail *agentTail) appendText(text string) {
	if len(text) == 0 {
		return
	}
	tail.grow(len(text))
	capacity := uint64(len(tail.data))
	next := tail.end + uint64(len(text))
	if len(text) > len(tail.data) {
		text = text[len(text)-len(tail.data):]
	}
	index := int((next - uint64(len(text))) % capacity)
	copied := copy(tail.data[index:], text)
	copy(tail.data, text[copied:])
	tail.end = next
	tail.lines[(tail.head+tail.count-1)%agentPreviewLines].end = next
	if next <= capacity {
		return
	}
	oldest := next - capacity
	for tail.count > 1 && tail.lines[tail.head].end <= oldest {
		tail.dropOldest()
	}
	first := &tail.lines[tail.head]
	if first.start < oldest {
		first.start = oldest
		for first.start < first.end && !utf8.RuneStart(tail.data[first.start%capacity]) {
			first.start++
		}
		tail.omitted = true
	}
}

func (tail *agentTail) write(text string, kind tailKind) {
	for {
		line, rest, newline := strings.Cut(text, "\n")
		if !tail.open {
			tail.begin(kind)
		}
		tail.appendText(line)
		if !newline {
			return
		}
		tail.open = false
		text = rest
	}
}

func (tail *agentTail) push(line tailLine) {
	tail.open = false
	tail.write(strings.TrimRight(line.text, " "), line.kind)
	tail.open = false
}

func (tail *agentTail) text(span agentTailSpan) string {
	if span.start == span.end {
		return ""
	}
	var text strings.Builder
	text.Grow(int(span.end - span.start))
	start := int(span.start % uint64(len(tail.data)))
	length := int(span.end - span.start)
	first := min(length, len(tail.data)-start)
	text.Write(tail.data[start : start+first])
	text.Write(tail.data[:length-first])
	return text.String()
}

// newest yields owned strings, so callers may retain them after a reset.
func (tail *agentTail) newest(trimNewlines bool) iter.Seq[tailLine] {
	return func(yield func(tailLine) bool) {
		trimming := trimNewlines
		for offset := tail.count - 1; offset >= 0; offset-- {
			span := tail.lines[(tail.head+offset)%agentPreviewLines]
			if trimming && span.start == span.end && offset > 0 {
				continue
			}
			trimming = false
			if !yield(tailLine{kind: span.kind, text: tail.text(span)}) {
				return
			}
		}
	}
}

type argumentPreviewState byte

const (
	argumentFindCode argumentPreviewState = iota
	argumentCodeQuote
	argumentRaw
	argumentCode
	argumentDone
)

type agentPreview struct {
	lines   agentTail
	matched int
	length  int
	pending [utf8.UTFMax]byte
	state   argumentPreviewState
	escaped bool
}

// Agent previews use the first literal "code" match and permissive escapes,
// exposing code while the argument JSON is still incomplete.
func (preview *agentPreview) appendArguments(text string) bool {
	if preview.state == argumentDone {
		return false
	}
	switch preview.state {
	case argumentFindCode, argumentCodeQuote, argumentRaw:
		preview.lines.write(text, tailCode)
	}
	for i := 0; i < len(text); i++ {
		ch := text[i]
		switch preview.state {
		case argumentFindCode:
			const key = `"code"`
			if ch == key[preview.matched] {
				preview.matched++
				if preview.matched == len(key) {
					preview.state = argumentCodeQuote
				}
			} else {
				preview.matched = 0
				if ch == key[0] {
					preview.matched = 1
				}
			}
		case argumentCodeQuote:
			switch ch {
			case ' ', ':':
			case '"':
				preview.lines = agentTail{}
				preview.lines.begin(tailCode)
				preview.state = argumentCode
			default:
				preview.state = argumentRaw
			}
		case argumentCode:
			if !preview.escaped && preview.length == 0 && ch < utf8.RuneSelf && ch != '\\' && ch != '"' {
				start := i
				for i+1 < len(text) && text[i+1] < utf8.RuneSelf && text[i+1] != '\\' && text[i+1] != '"' {
					i++
				}
				preview.lines.write(text[start:i+1], tailCode)
				continue
			}
			preview.pending[preview.length] = ch
			preview.length++
			for preview.length > 0 && utf8.FullRune(preview.pending[:preview.length]) {
				char, size := utf8.DecodeRune(preview.pending[:preview.length])
				copy(preview.pending[:], preview.pending[size:preview.length])
				preview.length -= size
				preview.appendCodeRune(char)
				if preview.state == argumentDone {
					return true
				}
			}
		case argumentRaw, argumentDone:
			return true
		}
	}
	return true
}

func (preview *agentPreview) appendCodeRune(char rune) {
	if preview.escaped {
		preview.escaped = false
		switch char {
		case 'n':
			preview.lines.write("\n", tailCode)
		case 't':
			preview.lines.write("    ", tailCode)
		default:
			preview.lines.write(string(char), tailCode)
		}
		return
	}
	switch char {
	case '\\':
		preview.escaped = true
	case '"':
		preview.state = argumentDone
	default:
		preview.lines.write(string(char), tailCode)
	}
}

func (preview *agentPreview) finish() {
	for preview.length > 0 {
		char, size := utf8.DecodeRune(preview.pending[:preview.length])
		copy(preview.pending[:], preview.pending[size:preview.length])
		preview.length -= size
		preview.appendCodeRune(char)
	}
}
