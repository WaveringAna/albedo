// Terminal escape replies and yes/no input must not accidentally approve destructive prompts; non-TTY E2E cannot exercise this parser.
package terminal

import (
	"testing"
)

func TestConfirmed(t *testing.T) {
	for answer, want := range map[string]bool{
		"y\n": true, " YES \n": true, "\x1b]11;rgb:1e1e/1e1e/2e2e\x1b\\\x1b[24;1Ry\n": true,
		"\n": false, "n\n": false, "": false, "yep\n": false,
	} {
		if got := Confirmed(answer); got != want {
			t.Errorf("Confirmed(%q) = %v, want %v", answer, got, want)
		}
	}
}
