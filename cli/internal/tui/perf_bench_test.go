// Benchmarks for the chat screen, as a yardstick for structural work on the
// client's cost model. Each one drives the code the client runs: Update for
// stream events and ticks, ChatModel.View for a frame, and the ultraviolet
// screen buffer bubbletea v2's renderer diffs the frame string into.
//
//	go -C cli test ./internal/tui -run XXX -bench . -benchmem -count=1
//	ALBEDO_BENCH_FIXTURE=/tmp/albedo-tui-perf/bench/session.json go -C cli test ...
//
// Without ALBEDO_BENCH_FIXTURE the transcript comes from a deterministic
// generator shaped like a real session (cli/cmd/tuifixture captures one).
package tui

import (
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/daemon/protocol"
	tea "charm.land/bubbletea/v2"
	uv "github.com/charmbracelet/ultraviolet"
)

// ---------------------------------------------------------------- fixtures

// perfFixture is a session to replay: the opening reset, and the events the
// daemon streams for its transcript.
type perfFixture struct {
	Session daemon.Session
	// Stream is what the opening stream carries: the newest page of rows.
	Stream []daemon.StreamEvent
	// Full is every row captured, for the hydrate ladder and scrolling.
	Full []daemon.StreamEvent
	// Before and More are where Stream starts in the transcript.
	Before int64
	More   bool
}

// capturedFixture mirrors cli/cmd/tuifixture's file. The two are deliberately
// separate: the tool must not import a test package, and the test must not
// depend on a file that only exists on the machine that captured it.
type capturedFixture struct {
	Session capturedSession      `json:"session"`
	Tail    []daemon.StreamEvent `json:"tail"`
	Full    []daemon.StreamEvent `json:"full"`
}

type capturedSession struct {
	ID              string              `json:"id"`
	Title           string              `json:"title"`
	Workspace       string              `json:"workspace"`
	Model           string              `json:"model"`
	Effort          string              `json:"effort"`
	Provider        string              `json:"provider"`
	TranscriptCount int                 `json:"transcript_count"`
	Status          daemon.AgentStatus  `json:"status"`
	Glances         []daemon.PageGlance `json:"glances"`
	Before          int64               `json:"before"`
	More            bool                `json:"more"`
}

func (c capturedFixture) fixture() perfFixture {
	return perfFixture{
		Session: daemon.Session{
			ID: c.Session.ID, Title: c.Session.Title, Workspace: c.Session.Workspace,
			Model: c.Session.Model, Effort: c.Session.Effort, Provider: c.Session.Provider,
			TranscriptCount: c.Session.TranscriptCount, Status: c.Session.Status, Glances: c.Session.Glances,
		},
		Stream: c.Tail,
		Full:   c.Full,
		Before: c.Session.Before,
		More:   c.Session.More,
	}
}

// perfSession is the session every benchmark opens unless a fixture names one.
func perfSession() daemon.Session {
	idle := daemon.PhaseIdle
	return daemon.Session{
		ID: "perf-session", Title: "perf", Workspace: "/Users/dawn/proj/albedo",
		Model: "claude-opus-5-5", Effort: "high", Provider: "claude",
		Status: daemon.AgentStatus{Phase: &idle, Idle: true, KernelLink: "attached"},
		Glances: []daemon.PageGlance{
			{Title: "active work", Rows: []daemon.PageRow{
				{ID: "118", Text: "private repos M3: sync surface for syncers", Tone: daemon.ToneActive},
				{ID: "121", Text: "respond to review on the group create path", Tone: daemon.ToneActive},
			}},
			{Title: "scheduled", Rows: []daemon.PageRow{
				{Text: "heartbeat: check the gate", Tone: daemon.ToneMuted},
			}},
			{Title: "kernel", Rows: []daemon.PageRow{
				{Text: "gate: running", Tone: daemon.ToneWarning},
			}},
		},
	}
}

// perfFixtureFor returns the fixture the benchmark runs on: the captured
// session when ALBEDO_BENCH_FIXTURE names one, the generator otherwise.
func perfFixtureFor(tb testing.TB) perfFixture {
	tb.Helper()
	path := os.Getenv("ALBEDO_BENCH_FIXTURE")
	if path == "" {
		return syntheticFixture()
	}
	data, err := os.ReadFile(path)
	if err != nil {
		tb.Fatalf("ALBEDO_BENCH_FIXTURE: %v", err)
	}
	var captured capturedFixture
	if err := json.Unmarshal(data, &captured); err != nil {
		tb.Fatalf("ALBEDO_BENCH_FIXTURE %s: %v", path, err)
	}
	return captured.fixture()
}

// syntheticFixture is a session of perfTurnCount turns of mixed prose, code,
// tables, tool calls and diffs. Sizes are taken from a captured session: a
// reply is ~560 bytes, a thought ~350, a tool result ~2 KB.
func syntheticFixture() perfFixture {
	session := perfSession()
	fixture := perfFixture{Session: session, Before: 1, More: true}
	var position int64 = 1
	for turn := range perfTurnCount {
		for _, event := range perfTurn(turn, &position) {
			fixture.Full = append(fixture.Full, event)
		}
	}
	// The opening stream carries the newest page, as the daemon's tail does.
	tail := 120
	if len(fixture.Full) > tail {
		fixture.Stream = fixture.Full[len(fixture.Full)-tail:]
	} else {
		fixture.Stream = fixture.Full
	}
	return fixture
}

// perfTurnCount is enough turns for the 5k-row hydrate ladder: a turn is
// about four rows and their committed stamps.
const perfTurnCount = 1200

// perfTurn is one user message and everything the agent answered it with.
func perfTurn(turn int, position *int64) []daemon.StreamEvent {
	at := *position
	*position = at + 1
	userAt := time.Unix(1792468600+int64(turn)*97, 0).UnixMilli()
	events := []daemon.StreamEvent{{
		Type: daemon.EventUser, EntryID: fmt.Sprintf("%d-user", at), Position: at,
		Text: perfUserText(turn), Source: "chat", Timestamp: &userAt, Replayed: true,
	}}
	at = *position
	*position = at + 1
	events = append(events, daemon.StreamEvent{
		Type: daemon.EventThinking, EntryID: fmt.Sprintf("%d-thinking", at), Position: at,
		Text: perfThought(turn), ElapsedMs: int64(400 + turn%2600), ElapsedObserved: true, Replayed: true,
	})
	at = *position
	*position = at + 1
	events = append(events, daemon.StreamEvent{
		Type: daemon.EventMessage, EntryID: fmt.Sprintf("%d-message", at), Position: at,
		Text: perfReplyText(turn), Timestamp: &userAt, Replayed: true,
	})
	if turn%3 != 2 {
		ms, ok := int64(120+turn%900), true
		trace := &daemon.ToolTrace{Activities: []daemon.ToolActivity{
			{Kind: "run", Target: "go -C cli test ./internal/tui -count=1", MS: &ms, OK: &ok},
			{Kind: "read", Target: "/Users/dawn/proj/albedo/cli/internal/tui/chat_view.go"},
		}}
		if turn%4 == 0 {
			trace.Changes = []daemon.FileChange{{
				Path:  "cli/internal/tui/chat_view.go",
				Kind:  "diff",
				Diff:  perfDiff(turn),
				Added: 6, Removed: 3,
			}}
		}
		at = *position
		*position = at + 1
		events = append(events, daemon.StreamEvent{
			Type: daemon.EventTool, EntryID: fmt.Sprintf("%d-tool", at), Position: at,
			ToolName: "python", ToolTrace: trace,
			ToolArgs:   map[string]any{"code": perfToolCode(turn)},
			ToolResult: perfToolResult(turn),
			Timestamp:  &userAt, Replayed: true,
		})
	}
	return events
}

func perfUserText(turn int) string {
	switch turn % 3 {
	case 0:
		return "why does an idle client still wake up? look at the renderer and the status poll, and tell me which of them costs more per second."
	case 1:
		return "can you take the join out of the frame path? it runs every frame even when nothing scrolled, and i want to see the numbers improve."
	default:
		return "run the benchmarks again on the branch, then post the frame numbers and the pprof top for the stream."
	}
}

func perfThought(turn int) string {
	return fmt.Sprintf("the frame path rebuilds the whole transcript string every tick, and the sidebar joins with lipgloss each time. the viewport only holds %d rows, so the work above it is wasted. i should check whether the join is the cost or the glamour block render.", 20+turn%30)
}

// perfReplyText is a reply the shape of a real one: a heading, prose, a list, a
// fenced block, a table, and inline code. The text is ordinary review prose; no
// number in it is a measurement, so a fixture can never be mistaken for one.
func perfReplyText(turn int) string {
	body := []string{
		"### where it goes wrong\n\nThe frame is assembled from rows: the transcript's visible slice, the notices above it, the rail and the status line, then the composer and the footer. Every row is a string with its own escape sequences, and the padding is `strings.Repeat`, so building the frame is mostly concatenation.\n\n- the transcript contributes its visible slice only\n- the composer renders through `textarea.Model.View`\n- the glances sidebar joins two columns\n\nWhat the frame is made of is simple. What the terminal does with it afterwards is the part worth reading.\n",
		"### the shape of the change\n\n```go\nfunc (m ChatModel) transcriptRows() []string {\n\trows := make([]string, 0, m.Viewport.Height())\n\tfor _, row := range m.Viewport.rows {\n\t\trows = append(rows, row)\n\t}\n\treturn rows\n}\n```\n\nKeeping the rows as rows, instead of joining them into one string, is what lets the sidebar pad them once rather than on every frame.\n",
		"| piece | owned by |\n| --- | --- |\n| transcript | `ChatModel.View` |\n| composer | `textarea.Model` |\n| sidebar | `sidebarRows` |\n| footer | `renderFooter` |\n\nEach one is independent, so each one is a candidate for caching on its own input rather than on the frame.\n",
		"### what to try first\n\n1. cache the composer's rendering until its value, width, or focus changes\n2. keep the sidebar's rows and rejoin them only when a glance changes\n3. strip the private row marks when rows are built, not on the whole frame\n\nNone of these changes what the screen says. They change how often the same work is done.\n",
	}
	return body[turn%len(body)]
}

func perfToolCode(turn int) string {
	return fmt.Sprintf("import json\nfor i in range(%d):\n    rows = [r for r in everything if r.get(%q)]\n    print(len(rows), sum(len(r[%q]) for r in rows))\n", 20+turn%40, "kind", "text")
}

func perfToolResult(turn int) string {
	var b strings.Builder
	for i := range 24 {
		fmt.Fprintf(&b, "%3d  cli/internal/tui/chat_view.go:%d  rows=%d width=%d bytes=%d\n", i, 380+i, 20+i%7, 100+i%9, 900+i*13)
	}
	return b.String()
}

// perfDiff is a numbered diff of the kind a tool trace carries.
func perfDiff(turn int) string {
	return fmt.Sprintf("@@ -380,9 +380,12 @@ func (m ChatModel) View() string {\n \tstatusStyle := DefaultStyles.Faint\n-\trows = append(rows, statusStyle.Render(status))\n+\trows = append(rows, statusStyle.Render(status))\n \tif len(m.effortOptions) == 0 {\n \t\trows = append(rows, m.chipStrip(width)...)\n \t}\n+\tif m.sidebarWidth() > 0 {\n+\t\trows = m.joinGlances(rows, width)\n+\t}\n \treturn strings.Join(rows, \"\\n\")\n")
}

// perfDeltas cuts text into provider-sized deltas: a few tokens each, never
// splitting a rune.
func perfDeltas(text string, size int) []string {
	sizes := []int{size, size * 2, size / 2, size * 3, size, size * 2}
	var deltas []string
	for at, step := 0, 0; at < len(text); step++ {
		n := sizes[step%len(sizes)]
		end := min(len(text), at+n)
		for end < len(text) && !utf8Start(text[end]) {
			end++
		}
		deltas = append(deltas, text[at:end])
		at = end
	}
	return deltas
}

func utf8Start(c byte) bool { return c&0xc0 != 0x80 }

// ---------------------------------------------------------------- the app

// perfApp opens the fixture's session the way the client does, at a size, and
// hydrates it from the daemon's stream events. Nothing is fetched: every
// command the model returns is dropped, so no benchmark touches a network or a
// daemon, and no clock is awaited.
func perfApp(tb testing.TB, fixture perfFixture, width, height int, flags DisplayFlags) *AppModel {
	tb.Helper()
	return perfAppWith(tb, fixture, width, height, flags, fixture.Stream)
}

// perfAppWith opens the session and hydrates it from events, which is what the
// stream does when it delivers a page.
func perfAppWith(tb testing.TB, fixture perfFixture, width, height int, flags DisplayFlags, events []daemon.StreamEvent) *AppModel {
	tb.Helper()
	session := fixture.Session
	conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, nil)
	app := NewAppModel(conn, Bootstrap{Settings: daemon.Settings{Profiles: config.Profiles{}}}, &session, session.Workspace, false, nil)
	tb.Cleanup(app.Chat.Close)
	app.Update(tea.WindowSizeMsg{Width: width, Height: height})
	app.Chat.Flags = flags
	perfFeed(app, append([]daemon.StreamEvent{perfReset(fixture)}, events...))
	return app
}

// perfReset is the reset a stream opens with: it carries the snapshot, which is
// where the status line and the sidebar come from.
func perfReset(fixture perfFixture) daemon.StreamEvent {
	session := fixture.Session
	return daemon.StreamEvent{Type: daemon.EventReset, Before: fixture.Before, More: fixture.More, Snapshot: &session}
}

// perfFeed delivers events through the app's Update, which is where a real
// client's do: AppModel.handleChatLifecycle forwards them to ChatModel.Update.
func perfFeed(app *AppModel, events []daemon.StreamEvent) {
	for _, event := range events {
		app.Update(ChatStreamEventMsg{SessionID: app.Chat.SessionID, Generation: app.Chat.Generation, Event: event})
	}
}

// perfWorking is the fixture's session with a job that outlived its grace: the
// client the idle measurements caught animating forever.
func perfWorking(session daemon.Session) daemon.Session {
	started := time.Now().Add(-4 * time.Minute).UnixMilli()
	jobs := int64(1)
	session.Status.RunningJobs = []protocol.KernelJob{{
		ID: "job-1", Command: "go -C cli test ./internal/tui -count=1", StartedAt: started,
	}}
	session.Status.KernelJobs = &jobs
	return session
}

// perfTerminal mirrors what bubbletea v2's cursedRenderer does with one frame:
// parse the view string into cells on a screen buffer sized to the frame, draw
// it, and diff it against the previous screen into the terminal writer.
type perfTerminal struct {
	width, height int
	screen        uv.ScreenBuffer
	renderer      *uv.TerminalRenderer
	out           *countingWriter
}

// countingWriter stands in for the terminal. A tty write is a syscall the
// benchmark should not measure, but how many bytes a frame sends is part of its
// cost, so it counts them.
type countingWriter struct{ bytes int64 }

func (w *countingWriter) Write(p []byte) (int, error) {
	w.bytes += int64(len(p))
	return len(p), nil
}

func newPerfTerminal(width, height int) *perfTerminal {
	// The environment a real client runs in: a 256-color terminal that reports
	// true color. Detection reads it because the writer is not a tty.
	env := []string{"TERM=xterm-256color", "COLORTERM=truecolor", "CLICOLOR_FORCE=1"}
	out := &countingWriter{}
	renderer := uv.NewTerminalRenderer(out, env)
	renderer.SetRelativeCursor(true)
	renderer.SetFullscreen(false)
	renderer.SetTabStops(-1)
	renderer.SetScrollOptim(true)
	renderer.Resize(width, height)
	return &perfTerminal{width: width, height: height, screen: uv.NewScreenBuffer(width, height), renderer: renderer, out: out}
}

// flush draws one frame and writes its diff, as cursedRenderer.flush does.
func (t *perfTerminal) flush(content string) {
	styled := uv.NewStyledString(content)
	// An inline frame is as tall as its own content, not the terminal.
	frameHeight := t.height
	if height := styled.Height(); height != frameHeight {
		frameHeight = height
	}
	if t.screen.Width() != t.width || t.screen.Height() != frameHeight {
		// A frame whose shape changed forces a full redraw, as the renderer
		// does when its buffer no longer matches the frame area.
		t.renderer.Erase()
		t.screen.Resize(t.width, frameHeight)
	}
	t.screen.Clear()
	styled.Draw(t.screen, t.screen.Bounds())
	if frameHeight > t.height {
		// The renderer drops the rows above the screen; keep the same cells and
		// the same work by dropping them here too.
		drop := frameHeight - t.height
		t.screen.Lines = t.screen.Lines[drop:]
		t.screen.Touched = t.screen.Touched[drop:]
	}
	t.renderer.Render(t.screen.RenderBuffer)
	_ = t.renderer.Flush()
}

func (t *perfTerminal) bytes() int64 { return t.out.bytes }

// ---------------------------------------------------------------- frames

// BenchmarkFrame is one full frame: the model's View plus everything the
// renderer then does with the string it returns.
func BenchmarkFrame(b *testing.B) {
	for _, size := range []struct {
		name          string
		width, height int
	}{{"200x50", 200, 50}, {"120x40", 120, 40}} {
		b.Run(size.name, func(b *testing.B) {
			benchmarkFrameModes(b, size.width, size.height)
		})
	}
}

func benchmarkFrameModes(b *testing.B, width, height int) {
	b.Run("resting/repeat", func(b *testing.B) {
		// The resting client: nothing animates and nothing scrolls, so the frame
		// is the same string every time. Its wire bytes are the steady state.
		fixture := perfFixtureFor(b)
		fixture.Session.Glances = nil
		app := perfApp(b, fixture, width, height, DisplayFlags{})
		terminal := newPerfTerminal(width, height)
		content := app.View().Content
		b.ReportAllocs()
		b.ResetTimer()
		for range b.N {
			terminal.flush(content)
		}
		b.ReportMetric(float64(terminal.bytes())/float64(b.N), "wire-B/frame")
	})

	b.Run("resting/view", func(b *testing.B) {
		// The string alone, so what building a frame costs and what drawing it
		// costs are separate numbers.
		fixture := perfFixtureFor(b)
		fixture.Session.Glances = nil
		app := perfApp(b, fixture, width, height, DisplayFlags{})
		b.ReportAllocs()
		b.ResetTimer()
		var size int
		for range b.N {
			size = len(app.View().Content)
		}
		b.ReportMetric(float64(size), "frame-B")
	})

	b.Run("glances/repeat", func(b *testing.B) {
		// An idle session whose extensions report work: every frame joins the
		// transcript and the sidebar with lipgloss.
		fixture := perfFixtureFor(b)
		app := perfApp(b, fixture, width, height, DisplayFlags{})
		if app.Chat.sidebarWidth() == 0 {
			b.Fatalf("%dx%d leaves no room for the sidebar", width, height)
		}
		terminal := newPerfTerminal(width, height)
		content := app.View().Content
		b.ReportAllocs()
		b.ResetTimer()
		for range b.N {
			terminal.flush(content)
		}
		b.ReportMetric(float64(terminal.bytes())/float64(b.N), "wire-B/frame")
	})

	b.Run("animating/face", func(b *testing.B) {
		// A job outlived its grace, so the client never rests: the face ticks and
		// every tick redraws the frame, which differs in the status line only.
		fixture := perfFixtureFor(b)
		fixture.Session = perfWorking(fixture.Session)
		app := perfApp(b, fixture, width, height, DisplayFlags{})
		terminal := newPerfTerminal(width, height)
		b.ReportAllocs()
		b.ResetTimer()
		for range b.N {
			app.Update(ChatProgressTickMsg{SessionID: app.Chat.SessionID, Generation: app.Chat.Generation})
			terminal.flush(app.View().Content)
		}
		b.ReportMetric(float64(terminal.bytes())/float64(b.N), "wire-B/frame")
	})

	b.Run("animating/view", func(b *testing.B) {
		// The tick and the string, without drawing it: the frame's share of the
		// wakeup, against animating/face's total.
		fixture := perfFixtureFor(b)
		fixture.Session = perfWorking(fixture.Session)
		app := perfApp(b, fixture, width, height, DisplayFlags{})
		b.ReportAllocs()
		b.ResetTimer()
		var size int
		for range b.N {
			app.Update(ChatProgressTickMsg{SessionID: app.Chat.SessionID, Generation: app.Chat.Generation})
			size = len(app.View().Content)
		}
		b.ReportMetric(float64(size), "frame-B")
	})

	b.Run("verbose/face", func(b *testing.B) {
		// Tools, thoughts and diffs expanded, which is the long-transcript case.
		fixture := perfFixtureFor(b)
		fixture.Session = perfWorking(fixture.Session)
		app := perfApp(b, fixture, width, height, DisplayFlags{Thinking: true, Tools: true, Diffs: true})
		terminal := newPerfTerminal(width, height)
		b.ReportAllocs()
		b.ResetTimer()
		for range b.N {
			app.Update(ChatProgressTickMsg{SessionID: app.Chat.SessionID, Generation: app.Chat.Generation})
			terminal.flush(app.View().Content)
		}
		b.ReportMetric(float64(terminal.bytes())/float64(b.N), "wire-B/frame")
	})
}

// ---------------------------------------------------------------- streaming

// BenchmarkStreamReply streams a ~30KB markdown reply as provider-sized text
// deltas through the app's Update, then settles it. The live-draw pacing runs
// as it does in the client: a delta that arrives inside the live interval is
// drawn by the next ChatLiveDrawMsg, and a virtual clock advances by each
// delta's arrival time so those draws land when they would.
func BenchmarkStreamReply(b *testing.B) {
	fixture := perfFixtureFor(b)
	reply := perfLongReply()
	deltas := perfDeltas(reply, 11)
	b.Logf("reply %d bytes in %d deltas", len(reply), len(deltas))

	for _, size := range []struct {
		name          string
		width, height int
	}{{"200x50", 200, 50}, {"120x40", 120, 40}} {
		b.Run(size.name, func(b *testing.B) {
			app := perfApp(b, fixture, size.width, size.height, DisplayFlags{})
			terminal := newPerfTerminal(size.width, size.height)
			// One short reply first, so style and renderer setup is not the
			// measurement.
			benchmarkStreamOnce(app, fixture, terminal, perfDeltas(perfReplyText(0), 11), perfReplyText(0))

			b.SetBytes(int64(len(reply)))
			b.ReportAllocs()
			b.ResetTimer()
			draws := 0
			for range b.N {
				draws = benchmarkStreamOnce(app, fixture, terminal, deltas, reply)
			}
			b.StopTimer()
			b.ReportMetric(float64(draws)/float64(b.N), "draws/op")
			b.ReportMetric(float64(len(deltas)), "deltas/op")
			if elapsed := b.Elapsed().Seconds(); elapsed > 0 {
				b.ReportMetric(float64(draws*b.N)/elapsed, "draws/s")
			}
		})
	}
}

// benchmarkStreamOnce starts a turn, streams the reply and settles it, and
// returns how many times the growing reply was rendered.
func benchmarkStreamOnce(app *AppModel, fixture perfFixture, terminal *perfTerminal, deltas []string, reply string) int {
	session := app.Chat.SessionID
	generation := app.Chat.Generation
	// Every reply starts from the same transcript, the way a reconnect's reset
	// leaves one, so iterations do not measure each other's history.
	app.Update(ChatStreamEventMsg{SessionID: session, Generation: generation, Event: perfReset(fixture)})
	app.Update(ChatStreamEventMsg{SessionID: session, Generation: generation, Event: daemon.StreamEvent{
		Type: daemon.EventUser, EntryID: "stream-user", Position: 1, Text: "hi", Source: "chat", Replayed: true,
	}})
	messageID := "stream-reply"
	draws := 0
	// A real stream arrives at a few hundred bytes a second, so a delta usually
	// outlives the 33ms live interval and is drawn inline.
	const rate = 320 // bytes per second
	var clock, next time.Duration
	for _, delta := range deltas {
		app.Update(ChatStreamEventMsg{SessionID: session, Generation: generation, Event: daemon.StreamEvent{
			Type: daemon.EventText, MessageID: messageID, Text: delta,
		}})
		if app.Chat.liveDue {
			if clock >= next {
				// The interval has passed; this is the tick's draw.
				app.Chat.liveDrawn = time.Time{}
				app.Update(ChatLiveDrawMsg{SessionID: session, Generation: generation})
				next, draws = clock+app.Chat.liveInterval, draws+1
			}
		} else {
			next, draws = clock+app.Chat.liveInterval, draws+1
		}
		clock += time.Duration(len(delta)) * time.Second / rate
	}
	terminal.flush(app.View().Content)
	// The turn's canonical reply arrives, and the commit retires the live text it
	// replaces: the message identity is the live stream's.
	at := int64(len(deltas) + 1)
	app.Update(ChatStreamEventMsg{SessionID: session, Generation: generation, Event: daemon.StreamEvent{
		Type: daemon.EventMessage, EntryID: messageID, MessageID: messageID, Position: at, Text: reply,
	}})
	app.Update(ChatStreamEventMsg{SessionID: session, Generation: generation, Event: daemon.StreamEvent{
		Type: daemon.EventCommitted, Seq: at, ReplacesLiveIDs: []string{messageID},
	}})
	terminal.flush(app.View().Content)
	return draws
}

// perfLongReply is a reply the size the client actually renders: sections of
// prose, lists, code, tables and inline code, about 30 KB.
func perfLongReply() string {
	var b strings.Builder
	for section := 0; b.Len() < 30_000; section++ {
		fmt.Fprintf(&b, "\n## %d · %s\n\n", section+1, perfReplyHeading(section))
		b.WriteString(perfReplyBody(section))
	}
	return b.String()
}

func perfReplyHeading(section int) string {
	headings := []string{
		"where a frame's time goes",
		"what the renderer does with the string",
		"pacing the live reply",
		"the sidebar join",
		"what an idle tick costs",
	}
	return headings[section%len(headings)]
}

// perfReplyBody is one section of the long reply. Like perfReplyText, no number
// in it is a measurement.
func perfReplyBody(section int) string {
	bodies := []string{
		"The frame walks the transcript rows, measures each one with `ansi.StringWidth`, and pads the rows beside the sidebar so the join has two rectangular blocks. That measurement runs for every row on every frame, whether or not either column changed.\n\n- `ChatModel.View` assembles rows into one string\n- the composer renders through `textarea.Model.View`\n- the sidebar joins two columns cell by cell\n\nNone of it is expensive on its own; together they run at every tick of the face.\n",
		"The renderer treats the frame as a terminal stream: it parses SGR sequences, measures grapheme clusters, and writes cells into a screen buffer that it then diffs against the previous screen. Because the client clears the buffer before every draw, every row is touched, so the diff is a full repaint in disguise.\n\n```go\nstyled := uv.NewStyledString(view.Content)\nscreen.Clear()\nstyled.Draw(screen, screen.Bounds())\nrenderer.Render(screen.RenderBuffer)\nrenderer.Flush()\n```\n",
		"A reply grows several times a second, and each rendering of it costs time proportional to its length, so the client redraws at most once per live interval: `max(liveFrame, 4x` the last rendering`)`. A draw that arrives inside the interval is deferred, and the next one draws whatever accumulated in the meantime.\n\n- the interval starts at one frame's worth of time\n- a slow rendering raises it for the rest of the reply\n- a deferred draw is never dropped, only postponed\n",
		"The sidebar is a second lipgloss block joined to the transcript with `JoinHorizontal`, which pads every row of both blocks to the same height and copies them cell by cell. It runs on every frame, including the ones where the sidebar is empty.\n\n1. build the sidebar rows\n2. pad the transcript rows\n3. join the two blocks\n\nThe join is the cheap part once the padding is done; the padding is what measures every row.\n",
		"An idle tick is a `ChatProgressTickMsg` plus a status read, and every one of them redraws the whole frame. A session with a job that never ends animates forever, which is where a resting client's CPU goes.\n\n`statusPollCmd` slows down only when nothing animates, and a background job counts as animating.\n",
	}
	return bodies[section%len(bodies)]
}

// ---------------------------------------------------------------- hydrate

// BenchmarkHydrate opens a session and replays the daemon's stream into it:
// the reset, then one event per transcript row, then the committed stamps. The
// retained heap is the model's after a collection, measured once outside the
// timed loop.
func BenchmarkHydrate(b *testing.B) {
	fixture := perfFixtureFor(b)
	for _, rows := range []int{1000, 5000} {
		b.Run(fmt.Sprintf("%d-entries", rows), func(b *testing.B) {
			events := perfHistory(fixture, rows)
			if len(events) == 0 {
				b.Fatalf("fixture has no rows to hydrate")
			}
			if len(events) < rows {
				b.Logf("fixture carries %d of %d rows", len(events), rows)
			}
			b.ReportAllocs()
			b.ResetTimer()
			for range b.N {
				perfApp(b, fixture, 200, 50, DisplayFlags{})
			}
			b.StopTimer()
			retained := perfRetained(func() any {
				app := perfApp(b, fixture, 200, 50, DisplayFlags{})
				return app
			})
			b.ReportMetric(float64(retained), "retained-B")
			b.ReportMetric(float64(len(events)), "events/op")
		})
	}
}

// perfHistory returns the newest rows of the fixture's transcript as the stream
// delivers them, with the committed stamps that follow each row.
func perfHistory(fixture perfFixture, rows int) []daemon.StreamEvent {
	full := fixture.Full
	if len(full) > rows {
		full = full[len(full)-rows:]
	}
	// A captured transcript already carries its committed stamps; the generator
	// leaves them for the benchmark to add, as the daemon does after a row.
	stamped := false
	for _, event := range full {
		if event.Type == daemon.EventCommitted {
			stamped = true
			break
		}
	}
	events := make([]daemon.StreamEvent, 0, len(full)*2)
	for _, event := range full {
		events = append(events, event)
		if !stamped && isRowEvent(event) {
			events = append(events, daemon.StreamEvent{Type: daemon.EventCommitted, Seq: event.Position, Replayed: true})
		}
	}
	return events
}

// isRowEvent reports whether an event carries a transcript row, which the
// daemon stamps as committed once it is written.
func isRowEvent(event daemon.StreamEvent) bool {
	switch event.Type {
	case daemon.EventUser, daemon.EventMessage, daemon.EventThinking, daemon.EventTool,
		daemon.EventNote, daemon.EventCompacted, daemon.EventError, daemon.EventTurnCompleted:
		return true
	}
	return false
}

// perfRetained measures the heap a build keeps once the garbage is collected.
func perfRetained(build func() any) uint64 {
	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	kept := build()
	runtime.KeepAlive(kept)
	runtime.GC()
	runtime.ReadMemStats(&after)
	return after.HeapAlloc - before.HeapAlloc
}

// ---------------------------------------------------------------- scrolling

// BenchmarkScroll pages from the bottom of a long transcript to the top and
// back, drawing a frame per step.
func BenchmarkScroll(b *testing.B) {
	fixture := perfFixtureFor(b)
	app := perfAppWith(b, fixture, 200, 50, DisplayFlags{}, perfHistory(fixture, len(fixture.Full)))
	terminal := newPerfTerminal(200, 50)

	b.ReportAllocs()
	b.ResetTimer()
	var steps int
	for range b.N {
		up, down := 0, 0
		for app.Chat.scrollOffset > 0 && up < 5000 {
			app.Update(tea.KeyPressMsg{Code: tea.KeyPgUp})
			terminal.flush(app.View().Content)
			up++
		}
		for !app.Chat.Follow && down < 5000 {
			app.Update(tea.KeyPressMsg{Code: tea.KeyPgDown})
			terminal.flush(app.View().Content)
			down++
		}
		steps += up + down
	}
	b.StopTimer()
	if steps == 0 {
		b.Fatal("the transcript did not scroll")
	}
	b.ReportMetric(float64(steps)/float64(b.N), "steps/op")
}

// ---------------------------------------------------------------- idle

// BenchmarkIdleTick is one wakeup of a client that never comes to rest: a face
// tick or an unchanged status poll, each followed by the frame it redraws.
func BenchmarkIdleTick(b *testing.B) {
	b.Run("face-tick", func(b *testing.B) {
		fixture := perfFixtureFor(b)
		fixture.Session = perfWorking(fixture.Session)
		app := perfApp(b, fixture, 200, 50, DisplayFlags{})
		terminal := newPerfTerminal(200, 50)
		session, generation := app.Chat.SessionID, app.Chat.Generation
		b.ReportAllocs()
		b.ResetTimer()
		for range b.N {
			app.Update(ChatProgressTickMsg{SessionID: session, Generation: generation})
			terminal.flush(app.View().Content)
		}
		b.StopTimer()
	})

	b.Run("status-poll", func(b *testing.B) {
		fixture := perfFixtureFor(b)
		fixture.Session = perfWorking(fixture.Session)
		app := perfApp(b, fixture, 200, 50, DisplayFlags{})
		terminal := newPerfTerminal(200, 50)
		session, generation := app.Chat.SessionID, app.Chat.Generation
		b.ReportAllocs()
		b.ResetTimer()
		for range b.N {
			status := app.Chat.Status
			glances := app.Chat.Glances
			app.Update(ChatStatusMsg{SessionID: session, Generation: generation, Revision: app.Chat.statusRevision, Status: &status, Glances: glances})
			terminal.flush(app.View().Content)
		}
		b.StopTimer()
	})
}
