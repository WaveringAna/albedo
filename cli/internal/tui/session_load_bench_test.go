package tui

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
)

// A frozen copy of one real session's transcript events, replayed through the
// model the way a stream reset and history pages deliver them. The identity
// digest covers the parsed history, not the rendered rows: rendering is what
// the arms differ in.
type sessionFixture struct {
	Session   string            `json:"session"`
	Workspace string            `json:"workspace"`
	Events    []json.RawMessage `json:"events"`
	Tail      []json.RawMessage `json:"tail"`
}

func benchSessionEvents(t *testing.T, scope string) ([]daemon.StreamEvent, string) {
	t.Helper()
	path := os.Getenv("ALBEDO_BENCH_EVENTS")
	if path == "" {
		t.Skip("ALBEDO_BENCH_EVENTS not set")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var fixture sessionFixture
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	raws := fixture.Events
	if scope == "tail" {
		raws = fixture.Tail
	}
	events := make([]daemon.StreamEvent, 0, len(raws))
	for _, raw := range raws {
		var mapEvent map[string]json.RawMessage
		if err := json.Unmarshal(raw, &mapEvent); err != nil {
			t.Fatal(err)
		}
		if args, ok := mapEvent["args"]; ok {
			var encoded string
			if json.Unmarshal(args, &encoded) == nil {
				mapEvent["args"] = []byte(encoded)
			}
		}
		encoded, err := json.Marshal(mapEvent)
		if err != nil {
			t.Fatal(err)
		}
		var e daemon.StreamEvent
		if err := json.Unmarshal(encoded, &e); err != nil {
			t.Fatal(err)
		}
		e.Replayed = true
		events = append(events, e)
	}
	return events, fixture.Workspace
}

// benchSessionPlan turns the event stream into the entries a replay settles:
// thinking chunks join into one entry per spell, commits stay gaps where the
// viewport still refreshes, as they do on a live stream.
func benchSessionPlan(events []daemon.StreamEvent) []*HistoryEntry {
	steps := make([]*HistoryEntry, len(events))
	pending, pendingAt := "", -1
	flush := func() {
		if pendingAt >= 0 {
			steps[pendingAt] = &HistoryEntry{Kind: EntryThinking, Text: pending}
			pending, pendingAt = "", -1
		}
	}
	for i, e := range events {
		switch e.Type {
		case daemon.EventThinking:
			pending += e.Text
			pendingAt = i
		case daemon.EventCommitted:
		case daemon.EventMessage:
			flush()
			steps[i] = &HistoryEntry{Kind: EntryAssistant, Speaker: "albedo", Text: e.Text}
		default:
			flush()
			entry := HistoryEntry{Text: e.Text}
			switch e.Type {
			case daemon.EventUser:
				entry.Kind, entry.Speaker = EntryUser, "You"
			case daemon.EventMessage:
				entry.Kind, entry.Speaker = EntryAssistant, "albedo"
			case daemon.EventTool:
				entry.Kind, entry.ToolName = EntryTool, e.ToolName
				entry.ToolArgs, entry.ToolResult, entry.ToolTrace = e.ToolArgs, e.ToolResult, e.ToolTrace
			default:
				continue
			}
			steps[i] = &entry
		}
	}
	flush()
	return steps
}

func entriesDigest(entries []HistoryEntry) string {
	h := sha256.New()
	for _, e := range entries {
		fmt.Fprintf(h, "%s\x00%s\x00%s\x00%s\x00%d\x00", e.Kind, e.Speaker, e.Text, e.ToolName, len(e.ToolResult))
		if e.ToolTrace != nil {
			for _, a := range e.ToolTrace.Activities {
				fmt.Fprintf(h, "a\x00%s\x00%s\x00", a.Kind, a.Target)
			}
			for _, c := range e.ToolTrace.Changes {
				fmt.Fprintf(h, "c\x00%s\x00%s\x00%d\x00%d\x00", c.Path, c.Kind, c.Added, c.Removed)
			}
		}
	}
	return fmt.Sprintf("%x", h.Sum(nil))
}

func TestSessionLoad(t *testing.T) {
	scope := os.Getenv("ALBEDO_BENCH_SCOPE")
	if scope != "tail" && scope != "full" {
		t.Skip("ALBEDO_BENCH_SCOPE not set")
	}
	events, workspace := benchSessionEvents(t, scope)
	steps := benchSessionPlan(events)
	m := NewChatModel(&daemon.Session{ID: "bench", Workspace: workspace}, nil)
	m.SetSize(100, 30)
	start := time.Now()
	for _, entry := range steps {
		if entry != nil {
			m.appendSettledEntry(*entry)
		}
		m.refreshViewportContent()
	}
	load := time.Since(start)
	m.rebuildSettledLines()
	m.refreshViewportContent()
	rendered := m.Renderer.RenderHistory(m.History, m.Flags)
	out, _ := json.Marshal(map[string]any{
		"entries_digest": entriesDigest(m.History.Entries()),
		"rendered_bytes": len(rendered),
		"settled_lines":  len(m.settledLines),
		"load_ms":        float64(load) / float64(time.Millisecond),
	})
	fmt.Println(string(out))
}
