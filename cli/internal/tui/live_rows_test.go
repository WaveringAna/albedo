// A live draw renders the reply's open block and keeps the blocks that already
// finished, so the rows it shows have to be exactly what rendering the whole
// reply at once gives: the daemon e2e never sees a live view, and a reply that
// reflowed when it settled would only show up here.
package tui

import (
	"slices"
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
)

var liveSampleReply = strings.Join([]string{
	"### where the rows come from",
	"",
	"the transcript holds each entry's rows, and a reply still arriving holds only",
	"the block it is writing: `markdownPiece` renders that block against the one",
	"before it.",
	"",
	"- the finished blocks are framed once",
	"- the open block is rendered again on each draw",
	"- every row is wrapped to the body width and hung on the rail",
	"",
	"| piece | cost |",
	"| --- | --- |",
	"| finished block | once |",
	"| open block | per draw |",
	"",
	"```go",
	"func (g *growingMarkdown) grow(text string, width int) bool {",
	"",
	"\treturn g.scanned <= len(text)",
	"}",
	"```",
	"",
	"$$",
	`\sum_{i=0}^{n} i = \frac{n(n+1)}{2}`,
	"$$",
	"",
	"and a closing paragraph, with `inline code` in it.",
	"",
}, "\n")

// liveDeltas cuts text into the uneven pieces a provider streams.
func liveDeltas(text string, size int) []string {
	var deltas []string
	for at := 0; at < len(text); {
		end := min(len(text), at+size+at%(size*3))
		for end < len(text) && text[end]&0xc0 == 0x80 {
			end++
		}
		deltas = append(deltas, text[at:end])
		at = end
	}
	return deltas
}

func TestLiveRowsMatchAWholeRender(t *testing.T) {
	for _, kind := range []struct {
		name  string
		event daemon.EventType
		entry EntryKind
		flags DisplayFlags
	}{
		{name: "reply", event: daemon.EventText, entry: EntryAssistant},
		{name: "thought", event: daemon.EventThinking, entry: EntryThinking, flags: DisplayFlags{Thinking: true}},
	} {
		for _, text := range []struct{ name, body string }{
			// a line reaching across blank lines keeps the reply whole, which
			// falls back to rendering it every draw
			{name: "raw html", body: "intro\n\n<pre>\nkeep\n\nthis\n</pre>\n\nafter"},
			{name: "sections", body: liveSampleReply},
		} {
			for _, width := range []int{36, 96} {
				t.Run(kind.name+"/"+text.name, func(t *testing.T) {
					m := newTestChatModel(t, &daemon.Session{ID: "s"})
					m.SetSize(width+8, 30)
					m.Flags = kind.flags
					m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventUser, Text: "write it out", Source: "chat"})
					m.refreshViewportContent()
					body := text.body
					if kind.entry == EntryThinking {
						body = "considering\n\n" + body
					}
					for i, delta := range liveDeltas(body, 7) {
						m.handleStreamEvent(daemon.StreamEvent{Type: kind.event, Text: delta, MessageID: "live-1"})
						m.refreshViewportContent()
						entry := HistoryEntry{Kind: kind.entry, Speaker: m.AgentName, Text: m.transcript.activeText, Live: true}
						want, _ := m.Renderer.Block(m.History.Entries(), entry, m.Flags)
						if !slices.Equal(m.liveRows, want) {
							t.Fatalf("delta %d (%q): live rows are not a whole render's\n got %q\nwant %q", i, delta, m.liveRows, want)
						}
					}
					live := m.Renderer.live
					if live == nil || len(live.rows) == 0 {
						t.Fatalf("nothing was kept between draws: %+v", live)
					}
					// the blocks that finished were framed once, not again per draw
					if text.name == "sections" && live.blocks.blockStart == 0 {
						t.Fatal("no block finished, so every draw rendered the whole reply")
					}
				})
			}
		}
	}
}
