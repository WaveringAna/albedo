// Terminal color reply parsing and contrast across palettes cannot be
// exercised by daemon E2E: they need a terminal that answers OSC queries, and
// the e2e harness has no PTY.
package tui

import (
	"math"
	"testing"
)

func hexColor(t *testing.T, h string) rgb {
	c := parseColors("\x1b]10;rgb:" + h[1:3] + "/" + h[3:5] + "/" + h[5:7] + "\x07").fg
	if c == nil {
		t.Fatalf("could not parse %s", h)
	}
	return *c
}

func TestParseColorReplies(t *testing.T) {
	c := parseColors("\x1b]10;rgb:cdcd/d6d6/f4f4\x1b\\\x1b]11;rgb:1e/1e/2e\x07\x1b]4;4;rgb:8989/b4b4/fafa\x1b\\\x1b]4;5;rgb:f5f5/c2c2/e7e7\x1b\\\x1b[?62;22c")
	if _, blue := c.palette[ansiBlue]; c.fg == nil || c.bg == nil || !blue || len(c.palette) != 2 {
		t.Fatalf("missing colors: %+v", c)
	}
	if got := c.fg.hex(); got != "#cdd6f4" {
		t.Fatalf("fg %s", got)
	}
	if got := c.bg.hex(); got != "#1e1e2e" {
		t.Fatalf("bg %s", got)
	}
	if got := parseColors("\x1b[?62;22c"); got.fg != nil || got.bg != nil {
		t.Fatal("a terminal that only answers device attributes reports no colors")
	}
}

func TestInkHitsItsContrastTargets(t *testing.T) {
	themes := map[string][2]string{
		"mocha": {"#cdd6f4", "#1e1e2e"},
		"latte": {"#4c4f69", "#eff1f5"},
		"black": {"#ffffff", "#000000"},
	}
	for name, theme := range themes {
		fg, bg := hexColor(t, theme[0]), hexColor(t, theme[1])
		mixed, ok := mixInk(termColors{fg: &fg, bg: &bg})
		if !ok {
			t.Fatal("colors were reported")
		}
		for _, step := range []struct {
			hex    string
			target float64
		}{{mixed.code, codeLc}, {mixed.secondary, secondaryLc}, {mixed.decor, decorLc}} {
			if got := apca(hexColor(t, step.hex), bg); math.Abs(got-step.target) > 1.5 {
				t.Errorf("%s: %s has Lc %.1f, want %v", name, step.hex, got, step.target)
			}
		}
	}
	soft, bg := hexColor(t, "#b3bbd7"), hexColor(t, "#1e1e2e")
	if mixed, _ := mixInk(termColors{fg: &soft, bg: &bg}); mixed.code != soft.hex() {
		t.Fatalf("text already under a target keeps its color, got %s", mixed.code)
	}
	black := hexColor(t, "#000000")
	if _, ok := mixInk(termColors{fg: &black, bg: &bg}); ok {
		t.Fatal("a text color barely apart from the background is not trusted")
	}
	if _, ok := mixInk(termColors{}); ok {
		t.Fatal("no reply leaves the palette fallbacks in place")
	}
}
