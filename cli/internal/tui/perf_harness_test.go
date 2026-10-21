// Sanity checks for the benchmark harness itself: a benchmark that silently
// measures an empty frame, or a renderer that never draws, would still pass.
package tui

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestPerfHarnessDrawsFrames checks that a hydrated fixture produces a frame the
// terminal can show, that styling survives, and that drawing it reaches the
// terminal.
func TestPerfHarnessDrawsFrames(t *testing.T) {
	fixture := perfFixtureFor(t)
	app := perfApp(t, fixture, 200, 50, DisplayFlags{})
	if app.Chat.History.Len() == 0 {
		t.Fatal("the fixture hydrated no history")
	}
	content := app.View().Content
	if len(content) == 0 {
		t.Fatal("the frame is empty")
	}
	if ansi.Strip(content) == content {
		t.Fatal("the frame carries no escape sequences at all")
	}
	for _, size := range []struct{ width, height int }{{200, 50}, {120, 40}} {
		app := perfApp(t, fixture, size.width, size.height, DisplayFlags{})
		content := app.View().Content
		terminal := newPerfTerminal(size.width, size.height)
		terminal.flush(content)
		first := terminal.bytes()
		if first == 0 {
			t.Fatal("the first frame reached the terminal as nothing")
		}
		terminal.flush(content)
		repeat := terminal.bytes() - first
		t.Logf("%dx%d: frame %d bytes, %d rows; first flush %d wire bytes, an unchanged repeat %d; screen %dx%d",
			size.width, size.height, len(content), strings.Count(content, "\n")+1, first, repeat,
			terminal.screen.Width(), terminal.screen.Height())
	}
}

// TestPerfStreamRenders checks that the stream benchmark's deltas really grow a
// live reply, that the model draws it more than once, and that it settles.
func TestPerfStreamRenders(t *testing.T) {
	fixture := perfFixtureFor(t)
	app := perfApp(t, fixture, 200, 50, DisplayFlags{})
	terminal := newPerfTerminal(200, 50)
	reply := perfLongReply()
	if len(reply) < 30_000 {
		t.Fatalf("the long reply is %d bytes, not about 30 KB", len(reply))
	}
	draws := benchmarkStreamOnce(app, fixture, terminal, perfDeltas(reply, 11), reply)
	if draws < 2 {
		t.Fatalf("the stream drew the growing reply %d times", draws)
	}
	settled := 0
	for _, entry := range app.Chat.History.Entries() {
		if entry.Kind == EntryAssistant && entry.Text == reply {
			settled++
		}
	}
	if settled != 1 {
		t.Fatalf("the reply settled into %d transcript entries, not one", settled)
	}
	if app.Chat.transcript.activeText != "" {
		t.Fatal("the live text outlived the commit that replaced it")
	}
}
