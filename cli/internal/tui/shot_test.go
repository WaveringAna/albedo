// Screenshots: a test that wants to look at a screen calls shot with what
// the view drew. Without ALBEDO_SHOT_DIR it does nothing, so the gate never
// writes files; test/manual/tui_shot.py turns the .ans files into PNGs.
package tui

import (
	"os"
	"path/filepath"
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

func TestShotExtensions(t *testing.T) {
	shotTerminal(t)
	m := NewExtensionPickerModel(nil, "s")
	m.SetSize(120, 28)
	m, _ = m.Update(extensionsLoadedMsg{Gen: m.Generation, Extensions: []ExtensionItem{
		{Name: "view", Description: "show the model its changes as highlighted images", Enabled: true, Overridden: true, Plugins: []string{"tool"}, Tools: []string{"view_diff"}},
		{Name: "bash", Description: "run shell commands", Enabled: true, GlobalEnabled: true, Plugins: []string{"tool", "context"}, Context: true},
		{Name: "webhooks", Description: "signed inbound requests wake a session"},
		{Name: "mcp", Description: "tool servers", GlobalEnabled: true, Quarantined: "failed to start"},
	}})
	shot(t, "extensions-wide", m.View())
	m.SetSize(70, 20)
	shot(t, "extensions-narrow", m.View())
}
