// Package display holds small rendering helpers, not an application framework.
package display

import (
	"strings"
	"unicode"
)

// BodyRows receives already-measured chrome heights, not guessed constants.
func BodyRows(total, header, footer int) int {
	return max(0, max(0, total)-max(0, header)-max(0, footer))
}

// Window keeps the current row visible and returns a half-open item range.
// It only applies to fixed-height, one-line rows.
func Window(total, cursor, top, height int) (int, int) {
	if total <= 0 || height <= 0 {
		return 0, 0
	}
	cursor = min(max(0, cursor), total-1)
	top = min(max(0, top), max(0, total-height))
	if cursor < top {
		top = cursor
	}
	if cursor >= top+height {
		top = cursor - height + 1
	}
	return top, min(total, top+height)
}

// SingleLine accepts plain data, not trusted ANSI. It neutralizes terminal
// controls by replacing every C0/C1 control with a space. Escape parameters
// remain visible text. This is deliberately not an ANSI-preserving sanitizer
// or a Unicode spoofing defense. Application styling is added AFTER this call.
func SingleLine(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || r == '\u2028' || r == '\u2029' {
			return ' '
		}
		return r
	}, strings.ToValidUTF8(s, "\uFFFD"))
}
