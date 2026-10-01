package daemon

import (
	"encoding/json"
	"strconv"
	"unicode/utf8"
)

// JSONStringDecoder consumes contents after a JSON string's opening quote.
// Its zero value is ready to use. It retains incomplete characters and escapes
// across Append calls, and stops at a closing quote or malformed escape.
type JSONStringDecoder struct {
	high       [6]byte
	escape     [6]byte
	pending    [utf8.UTFMax]byte
	escapeLen  int
	pendingLen int
	hasHigh    bool
	done       bool
}

func (d *JSONStringDecoder) Done() bool { return d.done }

// Append emits decoded text without retaining the input or accumulating output.
func (d *JSONStringDecoder) Append(text string, emit func(string)) {
	for i := 0; i < len(text) && !d.done; {
		ch := text[i]
		if d.escapeLen > 0 {
			d.escape[d.escapeLen] = ch
			d.escapeLen++
			i++
			if d.escapeLen == 2 && ch == 'u' {
				continue
			}
			if d.escape[1] == 'u' && d.escapeLen < len(d.escape) {
				continue
			}
			if !d.decodeEscape(emit) {
				d.Finish(emit)
			}
			d.escapeLen = 0
			continue
		}
		if d.pendingLen > 0 {
			// A non-continuation byte belongs to the next token.
			if ch&0xc0 != 0x80 {
				d.flushUTF8(emit)
				continue
			}
			d.pending[d.pendingLen] = ch
			d.pendingLen++
			i++
			if utf8.FullRune(d.pending[:d.pendingLen]) {
				d.flushUTF8(emit)
			}
			continue
		}
		switch {
		case ch == '"' || ch < 0x20:
			d.Finish(emit)
		case ch == '\\':
			d.escape[0], d.escapeLen = ch, 1
			i++
		case ch < utf8.RuneSelf:
			d.flushSurrogate(emit)
			start := i
			for i < len(text) && text[i] >= 0x20 && text[i] < utf8.RuneSelf && text[i] != '\\' && text[i] != '"' {
				i++
			}
			emit(text[start:i])
		case utf8.FullRuneInString(text[i:]):
			char, size := utf8.DecodeRuneInString(text[i:])
			d.emitRune(char, emit)
			i += size
		default:
			d.pendingLen = copy(d.pending[:], text[i:])
			return
		}
	}
}

// Only complete escapes reach encoding/json. A high surrogate waits for the
// following escape so the standard decoder can interpret the pair together.
func (d *JSONStringDecoder) decodeEscape(emit func(string)) bool {
	var decoded string
	atom := string(d.escape[:d.escapeLen])
	if json.Unmarshal([]byte(`"`+atom+`"`), &decoded) != nil {
		return false
	}
	if d.escapeLen == 6 {
		// encoding/json has already validated these hexadecimal digits.
		code, _ := strconv.ParseUint(atom[2:], 16, 16)
		if code >= 0xd800 && code <= 0xdbff {
			d.flushSurrogate(emit)
			d.high, d.hasHigh = d.escape, true
			return true
		}
	}
	if d.hasHigh {
		if json.Unmarshal([]byte(`"`+string(d.high[:])+atom+`"`), &decoded) != nil {
			return false
		}
		d.hasHigh = false
	}
	emit(decoded)
	return true
}

func (d *JSONStringDecoder) emitRune(char rune, emit func(string)) {
	d.flushSurrogate(emit)
	emit(string(char))
}

func (d *JSONStringDecoder) flushSurrogate(emit func(string)) {
	if d.hasHigh {
		emit(string(utf8.RuneError))
		d.hasHigh = false
	}
}

func (d *JSONStringDecoder) flushUTF8(emit func(string)) {
	for i := 0; i < d.pendingLen; {
		char, size := utf8.DecodeRune(d.pending[i:d.pendingLen])
		d.emitRune(char, emit)
		i += size
	}
	d.pendingLen = 0
}

// Finish settles incomplete UTF-8 and unpaired surrogates, discards an
// unfinished escape, and stops accepting input.
func (d *JSONStringDecoder) Finish(emit func(string)) {
	if d.done {
		return
	}
	d.flushUTF8(emit)
	d.flushSurrogate(emit)
	d.done = true
}
