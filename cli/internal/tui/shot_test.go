// Screenshots: a test that wants to look at a screen calls shot with what
// the view drew. Without ALBEDO_SHOT_DIR it does nothing, so the gate never
// writes files; test/manual/tui_shot.py turns the .ans files into PNGs.
package tui

import (
	"maps"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// shotTerminal makes the styles what a catppuccin terminal that reported its
// colors gets, as a user's terminal does, instead of the palette-slot
// fallback tests otherwise see (reverse video selection, no tints). It
// restores them after the test, and does nothing without ALBEDO_SHOT_DIR.
func shotTerminal(t *testing.T) {
	t.Helper()
	if os.Getenv("ALBEDO_SHOT_DIR") == "" {
		return
	}
	styles, ramp := DefaultStyles, transcriptInk
	t.Cleanup(func() { DefaultStyles, transcriptInk = styles, ramp })
	palette := map[int]rgb{}
	for slot, hex := range map[int]string{ansiRed: "#f38ba8", ansiGreen: "#a6e3a1", ansiBlue: "#89b4fa", ansiMagenta: "#cba6f7", ansiCyan: "#94e2d5"} {
		palette[slot] = *parseHex(hex)
	}
	colors := termColors{fg: parseHex("#cdd6f4"), bg: parseHex("#1e1e2e"), palette: palette}
	mixed, ok := mixInk(colors)
	if !ok {
		t.Fatal("the mock terminal colors were not trusted")
	}
	useInk(mixed)
}

func shot(t *testing.T, name, view string) {
	t.Helper()
	dir := os.Getenv("ALBEDO_SHOT_DIR")
	if dir == "" {
		return
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, name+".ans"), []byte(view), 0o644); err != nil {
		t.Fatal(err)
	}
}

// A shot size is a terminal to draw every state in.
type shotSize struct {
	name          string
	width, height int
}

var shotSizes = []shotSize{{"wide", 120, 30}, {"narrow", 70, 20}}

// A shot state is one situation of a screen: how it draws in a terminal of
// the given size.
type shotState struct {
	name string
	view func(width, height int) string
}

var shotScreens = map[string][]shotState{}

// registerShots lists the states a screen can be in, from an init in the
// screen's shot_<screen>_test.go, so the gallery draws all of them in every
// size. Cover what a person would want to look at: the list, a filter typed,
// each confirmation, loading, empty, failure, a notice, a form open.
func registerShots(screen string, states ...shotState) {
	shotScreens[screen] = append(shotScreens[screen], states...)
}

// TestShotGallery draws every registered state at every size to
// $ALBEDO_SHOT_DIR/<screen>--<state>--<size>.ans. Without the variable it
// still draws them, which keeps each state buildable. Run one screen with
// -run TestShotGallery/<screen>.
func TestShotGallery(t *testing.T) {
	shotTerminal(t)
	for _, screen := range slices.Sorted(maps.Keys(shotScreens)) {
		t.Run(screen, func(t *testing.T) {
			for _, state := range shotScreens[screen] {
				for _, size := range shotSizes {
					view := state.view(size.width, size.height)
					if view == "" {
						t.Errorf("%s/%s drew nothing at %s", screen, state.name, size.name)
					}
					shot(t, screen+"--"+state.name+"--"+size.name, view)
				}
			}
		})
	}
}
