package terminal

import (
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"

	uv "github.com/charmbracelet/ultraviolet"
)

// the TUI's renderer diffs frames through ultraviolet, and cli/third_party
// replaces it with a copy whose cells are 40 bytes instead of 112 (see
// third_party/ultraviolet.patch). what a terminal receives must not change,
// so the copy is only worth keeping while it renders the same bytes: the
// goldens in testdata/ultraviolet_frames.golden were taken from the unpatched
// module, and every step of this script is compared against them byte for
// byte.
func TestUltravioletRendersLikeStock(t *testing.T) {
	golden, err := os.ReadFile("testdata/ultraviolet_frames.golden")
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Split(strings.TrimSuffix(string(golden), "\n"), "\n")
	if len(want) != len(uvSteps) {
		t.Fatalf("golden has %d steps, the script has %d", len(want), len(uvSteps))
	}

	term := newFrameTerminal(60, 20)
	for i, step := range uvSteps {
		quoted, err := strconv.Unquote(strings.TrimSpace(want[i]))
		if err != nil {
			t.Fatalf("golden step %d (%s): %v", i, step.name, err)
		}
		if step.width > 0 {
			term.resize(step.width, step.height)
		}
		if step.flush {
			term.flush(step.frame)
		}
		got := term.take()
		if got != quoted {
			t.Fatalf("step %d (%s) wrote\n got: %q\nwant: %q", i, step.name, got, quoted)
		}
	}
}

// TestUltravioletIsThePatchedCopy catches a dependency bump that drops the
// replace and quietly restores 112-byte cells.
func TestUltravioletIsThePatchedCopy(t *testing.T) {
	mod, err := os.ReadFile("../../go.mod")
	if err != nil {
		t.Fatal(err)
	}
	replace := regexp.MustCompile(`(?m)^replace github\.com/charmbracelet/ultraviolet => \./third_party/ultraviolet$`)
	if !replace.Match(mod) {
		t.Fatal("cli/go.mod no longer replaces ultraviolet with third_party/ultraviolet (see third_party/ultraviolet.patch)")
	}
}

// uvStep is one thing a renderer is asked to do: resize the terminal, draw a
// frame, or both, in the order the client does them.
type uvStep struct {
	name          string
	width, height int // a resize, when width is set
	flush         bool
	frame         string
}

// uvSteps is a script that covers what a frame can hold: colors in all three
// encodings, every attribute and underline style, hyperlinks (including one
// that spans a style change and one that changes mid-line), wide graphemes
// (CJK, emoji, ZWJ sequences, flags, combining marks, variation selectors),
// a line wider than the screen, box drawing, trailing spaces and blank lines,
// a restart of the same frames, two resizes, a frame taller than the screen
// and an empty frame.
var uvSteps = []uvStep{
	{name: "plain", flush: true, frame: "hello world\nsecond line\n"},
	{name: "colors", flush: true, frame: "\x1b[31mred\x1b[0m \x1b[38;5;208morange\x1b[0m \x1b[38;2;12;34;56mtruecolor\x1b[0m\n" +
		"\x1b[44mblue bg\x1b[0m \x1b[48;5;236mdark bg\x1b[0m \x1b[48;2;1;2;3mrgb bg\x1b[0m\n"},
	{name: "attributes", flush: true, frame: "\x1b[1mbold\x1b[22m \x1b[2mfaint\x1b[22m \x1b[3mitalic\x1b[23m \x1b[7mreverse\x1b[27m \x1b[9mstruck\x1b[29m\n" +
		"\x1b[4munderline\x1b[24m \x1b[4:2mdouble\x1b[24m \x1b[4:3mcurly\x1b[24m \x1b[4:4mdotted\x1b[24m \x1b[4:5mdashed\x1b[24m\n" +
		"\x1b[58;5;93munderline color\x1b[59m \x1b[1;3;4;31mmixed\x1b[0m\n"},
	{name: "links", flush: true, frame: "\x1b]8;;https://example.com/a\x1b\\linked text\x1b]8;;\x1b\\ plain\n" +
		"\x1b]8;id=42;https://example.com/b\x1b\\\x1b[32mgreen link\x1b[0m still linked\x1b]8;;\x1b\\\n" +
		"\x1b]8;;https://example.com/c\x1b\\first\x1b]8;;https://example.com/d\x1b\\second\x1b]8;;\x1b\\\n"},
	{name: "wide graphemes", flush: true, frame: "漢字とかな mixed ascii 漢\n" +
		"emoji 🙂 👍🏽 done\n" +
		"family 👨\u200d👩\u200d👧\u200d👦 stays one glyph\n" +
		"flags 🇯🇵 🇺🇸 pair\n" +
		"combining a\u0301 e\u0308 n\u0303\n" +
		"selector 漢\uFE0F text\n"},
	{name: "wide line", flush: true, frame: "wide line: " + strings.Repeat("abcdefghij", 12) + "\n"},
	{name: "box drawing", flush: true, frame: "╭─────┬─────╮\n│ one │ two │\n╰─────┴─────╯\n" + strings.Repeat("─", 60) + "\n"},
	{name: "padding", flush: true, frame: "padded     \n\n\n     indented\n"},
	{name: "repeat plain", flush: true, frame: "hello world\nsecond line\n"},
	{name: "repeat colors", flush: true, frame: "\x1b[31mred\x1b[0m \x1b[38;5;208morange\x1b[0m \x1b[38;2;12;34;56mtruecolor\x1b[0m\n" +
		"\x1b[44mblue bg\x1b[0m \x1b[48;5;236mdark bg\x1b[0m \x1b[48;2;1;2;3mrgb bg\x1b[0m\n"},
	{name: "repeat links", flush: true, frame: "\x1b]8;;https://example.com/a\x1b\\linked text\x1b]8;;\x1b\\ plain\n" +
		"\x1b]8;id=42;https://example.com/b\x1b\\\x1b[32mgreen link\x1b[0m still linked\x1b]8;;\x1b\\\n" +
		"\x1b]8;;https://example.com/c\x1b\\first\x1b]8;;https://example.com/d\x1b\\second\x1b]8;;\x1b\\\n"},
	{name: "narrow resize", width: 30, height: 20},
	{name: "narrow plain", flush: true, frame: "hello world\nsecond line\n"},
	{name: "narrow wide graphemes", flush: true, frame: "漢字とかな mixed ascii 漢\n" +
		"emoji 🙂 👍🏽 done\n" +
		"family 👨\u200d👩\u200d👧\u200d👦 stays one glyph\n" +
		"flags 🇯🇵 🇺🇸 pair\n"},
	{name: "narrow wide line", flush: true, frame: "wide line: " + strings.Repeat("abcdefghij", 12) + "\n"},
	{name: "wide resize", width: 80, height: 24},
	{name: "wide box drawing", flush: true, frame: "╭─────┬─────╮\n│ one │ two │\n╰─────┴─────╯\n" + strings.Repeat("─", 60) + "\n"},
	{name: "wide attributes", flush: true, frame: "\x1b[1mbold\x1b[22m \x1b[2mfaint\x1b[22m \x1b[3mitalic\x1b[23m \x1b[7mreverse\x1b[27m \x1b[9mstruck\x1b[29m\n" +
		"\x1b[4munderline\x1b[24m \x1b[4:2mdouble\x1b[24m \x1b[4:3mcurly\x1b[24m \x1b[4:4mdotted\x1b[24m \x1b[4:5mdashed\x1b[24m\n" +
		"\x1b[58;5;93munderline color\x1b[59m \x1b[1;3;4;31mmixed\x1b[0m\n"},
	{name: "short resize", width: 40, height: 10},
	{name: "tall frame", flush: true, frame: tallFrame()},
	{name: "empty frame", flush: true},
	{name: "plain again", flush: true, frame: "hello world\nsecond line\n"},
}

// tallFrame is 30 rows on a 10 row screen: the inline renderer draws the whole
// frame and shows its last rows.
func tallFrame() string {
	var b strings.Builder
	for i := range 30 {
		fmt.Fprintf(&b, "\x1b[3%dmrow %d\x1b[0m with \x1b]8;;https://example.com/%d\x1b\\a link\x1b]8;;\x1b\\\n", i%8, i, i)
	}
	return b.String()
}

// frameTerminal draws frames the way bubbletea v2's cursedRenderer.flush does
// and keeps every byte the renderer wrote, for the test to compare.
type frameTerminal struct {
	width, height int
	screen        uv.ScreenBuffer
	renderer      *uv.TerminalRenderer
	out           strings.Builder
}

func newFrameTerminal(width, height int) *frameTerminal {
	// The environment a real client runs in: a 256-color terminal that reports
	// true color. Detection reads it because the writer is not a tty.
	env := []string{"TERM=xterm-256color", "COLORTERM=truecolor", "CLICOLOR_FORCE=1"}
	t := &frameTerminal{width: width, height: height}
	t.renderer = uv.NewTerminalRenderer(&t.out, env)
	t.renderer.SetRelativeCursor(true)
	t.renderer.SetFullscreen(false)
	t.renderer.SetTabStops(-1)
	t.renderer.SetScrollOptim(true)
	t.renderer.Resize(width, height)
	t.screen = uv.NewScreenBuffer(width, height)
	return t
}

func (t *frameTerminal) take() string {
	got := t.out.String()
	t.out.Reset()
	return got
}

func (t *frameTerminal) resize(width, height int) {
	t.renderer.Erase()
	t.width, t.height = width, height
	t.renderer.Resize(width, height)
	t.screen.Resize(width, height)
}

// flush mirrors cursedRenderer.flush: an inline frame is as tall as its own
// content, so the screen buffer follows the frame height, and the rows above
// the terminal are dropped after drawing.
func (t *frameTerminal) flush(content string) {
	styled := uv.NewStyledString(content)
	frameHeight := t.height
	if height := styled.Height(); height != frameHeight {
		frameHeight = height
	}
	if t.screen.Width() != t.width || t.screen.Height() != frameHeight {
		// A frame whose shape changed forces a full redraw, as the renderer
		// does when its buffer no longer matches the frame area.
		t.renderer.Erase()
		t.screen.Touched = nil
		t.screen.Resize(t.width, frameHeight)
	}
	t.screen.Clear()
	styled.Draw(t.screen, t.screen.Bounds())
	if frameHeight > t.height {
		drop := frameHeight - t.height
		t.screen.Lines = t.screen.Lines[drop:]
		t.screen.Touched = t.screen.Touched[drop:]
	}
	t.renderer.Render(t.screen.RenderBuffer)
	_ = t.renderer.Flush()
	// the renderer's own diff is not the only way a buffer reaches a string:
	// lipgloss composes frames through Buffer.Render, so the line renderer is
	// part of what a terminal receives.
	fmt.Fprintf(&t.out, "|render|%s|lines|%s", t.screen.Render(), t.screen.String())
}

// TestUpdateUltravioletGoldens rewrites the goldens the comparison uses: one
// quoted line per step. It skips itself unless frameGolden is set, so the file
// can be regenerated from an unpatched build by dropping the replace, running
// that test, and putting the replace back.
const frameGolden = "UPDATE_UV_FRAMES"

func TestUpdateUltravioletGoldens(t *testing.T) {
	if os.Getenv(frameGolden) == "" {
		t.Skip("set " + frameGolden + "=1 to rewrite testdata/ultraviolet_frames.golden")
	}
	var b strings.Builder
	term := newFrameTerminal(60, 20)
	for _, step := range uvSteps {
		if step.width > 0 {
			term.resize(step.width, step.height)
		}
		if step.flush {
			term.flush(step.frame)
		}
		fmt.Fprintf(&b, "%s\n", strconv.Quote(term.take()))
	}
	if err := os.WriteFile("testdata/ultraviolet_frames.golden", []byte(b.String()), 0o644); err != nil {
		t.Fatal(err)
	}
}
