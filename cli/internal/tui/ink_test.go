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

func TestCodeTintSteps(t *testing.T) {
	cases := []struct {
		name         string
		fg, bg, blue string
		to           string
		want         float64
	}{
		{"black bg tints toward blue", "#cdd6f4", "#000000", "#89b4fa", "#89b4fa", darkCodeBgRatio},
		{"mocha tints toward blue", "#cdd6f4", "#1e1e2e", "#89b4fa", "#89b4fa", darkCodeBgRatio},
		{"latte steps toward the text", "#4c4f69", "#eff1f5", "#1e66f5", "#4c4f69", lightCodeBgRatio},
		{"no blue reported steps toward the text", "#cdd6f4", "#1e1e2e", "", "#cdd6f4", darkCodeBgRatio},
	}
	for _, tc := range cases {
		fg, bg := hexColor(t, tc.fg), hexColor(t, tc.bg)
		colors := termColors{fg: &fg, bg: &bg, palette: map[int]rgb{}}
		if tc.blue != "" {
			colors.palette[ansiBlue] = hexColor(t, tc.blue)
		}
		mixed, _ := mixInk(colors)
		tint := hexColor(t, mixed.codeBg)
		if got := ratio(bg, tint); math.Abs(got-tc.want) > 0.03 {
			t.Errorf("%s: %s is %.2f:1 from the background, want %v", tc.name, mixed.codeBg, got, tc.want)
		}
		if want := step(bg, hexColor(t, tc.to), tc.want).hex(); mixed.codeBg != want {
			t.Errorf("%s: tint %s, want %s stepped toward %s", tc.name, mixed.codeBg, want, tc.to)
		}
	}
}
