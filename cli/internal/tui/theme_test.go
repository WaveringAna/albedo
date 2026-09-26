package tui

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// Colors are chosen in the theme alone. A screen that picks its own drifts
// from the rest, which is how the session screen grew a second palette.
func TestColorsComeFromTheTheme(t *testing.T) {
	owners := map[string]bool{"theme.go": true, "ink.go": true, "ink_unix.go": true, "ink_other.go": true}
	raw := regexp.MustCompile(`lipgloss\.Color\(|AdaptiveColor|\\x1b\[(3\d|4\d|9\d|7|38;|48;)|Faint\(true\)|Reverse\(true\)|"#[0-9a-fA-F]{6}"|\.Foreground\(|\)\.Background\(`)
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") || owners[name] {
			continue
		}
		src, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		for i, line := range strings.Split(string(src), "\n") {
			if raw.MatchString(line) {
				t.Errorf("%s:%d picks its own color, use a theme token: %s", name, i+1, strings.TrimSpace(line))
			}
		}
	}
}

// A full reset comes as "ESC[m" from Lip Gloss and "ESC[0m" from the raw ink;
// the selection surface and a diff row's tint must survive both.
func TestBackgroundsOutliveStyledSpans(t *testing.T) {
	span := DefaultStyles.Muted.Render("a")
	marked := DefaultStyles.Selected.Render("\x00")
	open := marked[:strings.IndexByte(marked, 0)]
	if line := selectedLine(span+" b", 0); !strings.Contains(line, open+" b") {
		t.Errorf("selection surface ends at the first span: %q", line)
	}
	if kept := keepBackground(span); strings.Contains(kept, "\x1b[m") || strings.Contains(kept, "\x1b[0m") {
		t.Errorf("a span still resets the row tint: %q", kept)
	}
}

// The header's ramp renders once per ink, and a new ink renders it anew.
func TestBrandRampFollowsTheInk(t *testing.T) {
	before, styles := transcriptInk, DefaultStyles
	defer func() { transcriptInk, DefaultStyles = before, styles }()
	useInk(ink{code: "#c0c0c0", secondary: "#808080", decor: "#404040", brandFrom: "#e08cf5", brandTo: "#6fd1c4"})
	pink := titleRule(80, brand("albedo"), "")
	if again := titleRule(80, brand("albedo"), ""); again != pink {
		t.Fatalf("the same ink rendered a different header:\n%q\n%q", pink, again)
	}
	useInk(ink{code: "#c0c0c0", secondary: "#808080", decor: "#404040", brandFrom: "#f0c674", brandTo: "#80aaf9"})
	if gold := titleRule(80, brand("albedo"), ""); gold == pink {
		t.Fatal("a new ink kept the old header")
	}
}
