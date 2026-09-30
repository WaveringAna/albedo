package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"time"
)

// transcriptState buffers streamed entries and tracks the turn in progress.
type transcriptState struct {
	activeKind ActiveStreamKind
	activeText string
	// Live thoughts are timed here; replayed thoughts carry daemon elapsed time.
	thinkingSince time.Time
	thoughtMs     int64
	// Summarized thinking arrives after it is written, so its start is the last
	// live event other than thinking rather than its first received delta.
	lastEvent time.Time

	streamedHash uint64
	streamedLen  int64
	turn         *openTurn
}

func newTranscriptState() transcriptState {
	return transcriptState{streamedHash: fnvOffset64}
}

func (t *transcriptState) resetStream() {
	t.activeKind, t.activeText = StreamKindNone, ""
	t.streamedHash, t.streamedLen = fnvOffset64, 0
}

func (t transcriptState) activeEntryKind() EntryKind {
	return pick(t.activeKind == StreamKindThinking, EntryThinking, EntryAssistant)
}

func (t *transcriptState) settle(agentName string) []HistoryEntry {
	var entries []HistoryEntry
	if t.activeKind != StreamKindNone && t.activeText != "" {
		entry := HistoryEntry{
			Kind:      t.activeEntryKind(),
			Speaker:   agentName,
			Text:      t.activeText,
			Timestamp: time.Now().UnixMilli(),
		}
		if entry.Kind == EntryThinking {
			entry.ElapsedMs = t.thoughtMs
			if !t.thinkingSince.IsZero() {
				entry.ElapsedMs = time.Since(t.thinkingSince).Milliseconds()
			}
		}
		entries = append(entries, entry)
	}
	t.activeKind, t.activeText = StreamKindNone, ""
	t.thinkingSince, t.thoughtMs = time.Time{}, 0
	return entries
}

func (t *transcriptState) streamDelta(kind ActiveStreamKind, text, agentName string) []HistoryEntry {
	if text == "" {
		return nil
	}
	t.turnIsLive()
	var entries []HistoryEntry
	if t.activeKind != kind {
		entries = t.settle(agentName)
		t.activeKind = kind
	}
	t.activeText += text
	if kind == StreamKindText {
		t.streamedHash = fnv1a(t.streamedHash, text)
		t.streamedLen += int64(len(text))
	}
	if len(t.activeText) > MaxLiveStreamBytes {
		// One long thought splits into entries, each timed from its own start.
		watched := !t.thinkingSince.IsZero()
		entries = append(entries, t.settle(agentName)...)
		t.activeKind = kind
		if watched {
			t.thinkingSince = time.Now()
		}
	}
	return entries
}

// apply returns newly settled entries. The history owner stamps committed rows.
func (t *transcriptState) apply(evt daemon.StreamEvent, agentName string) []HistoryEntry {
	thoughtStart := cmp.Or(t.lastEvent, time.Now())
	if !evt.Replayed && evt.Type != daemon.EventThinking {
		t.lastEvent = time.Now()
	}
	var entries []HistoryEntry
	switch evt.Type {
	case daemon.EventReset:
		t.resetStream()
		t.thinkingSince, t.thoughtMs = time.Time{}, 0
		t.turn = nil
	case daemon.EventRetry:
		t.resetStream()
	case daemon.EventUser:
		entries = t.settle(agentName)
		speaker := pick(evt.Source != "" && evt.Source != "chat", evt.Source, "You")
		var ts int64
		if evt.Timestamp != nil && *evt.Timestamp > 0 {
			ts = *evt.Timestamp
		} else if evt.TriggeredAt != "" {
			if parsed, err := time.Parse(time.RFC3339, evt.TriggeredAt); err == nil {
				ts = parsed.UnixMilli()
			}
		}
		// Your message closes the previous turn. Other sources open a turn
		// only when none is in flight.
		opens := t.turn == nil || speaker == "You"
		if opens {
			entries = append(entries, t.closeTurn(false)...)
		}
		entries = append(entries, HistoryEntry{
			Kind: EntryUser, Speaker: speaker, Text: evt.Text,
			ClientID: evt.ClientID, Timestamp: ts,
		})
		if opens {
			t.turn = newOpenTurn(ts)
		}
	case daemon.EventText:
		entries = t.streamDelta(StreamKindText, evt.Text, agentName)
	case daemon.EventThinking:
		if t.activeKind != StreamKindThinking {
			entries = t.settle(agentName)
			t.activeKind = StreamKindThinking
			if !evt.Replayed {
				t.thinkingSince = thoughtStart
			}
		}
		t.thoughtMs += evt.ElapsedMs
		entries = append(entries, t.streamDelta(StreamKindThinking, evt.Text, agentName)...)
	case daemon.EventToolProgress:
		if !evt.Replayed {
			t.turnIsLive()
			if evt.Progress != nil {
				entries = t.settle(agentName)
			}
		}
	case daemon.EventTool:
		entries = t.settle(agentName)
		entries = append(entries, HistoryEntry{
			Kind: EntryTool, ToolName: evt.ToolName, ToolArgs: evt.ToolArgs,
			ToolResult: evt.ToolResult, ToolTrace: evt.ToolTrace,
			Timestamp: time.Now().UnixMilli(),
		})
		if t.turn == nil {
			t.turn = newOpenTurn(0)
		}
		t.turn.tools++
		t.turn.touch(evt.Timestamp)
	case daemon.EventMessage:
		targetHash := fnv1a(fnvOffset64, evt.Text)
		duplicate := t.streamedLen == int64(len(evt.Text)) && t.streamedHash == targetHash
		t.streamedHash, t.streamedLen = fnvOffset64, 0
		entries = t.settle(agentName)
		if duplicate {
			return entries
		}
		var ts int64
		if evt.Timestamp != nil && *evt.Timestamp > 0 {
			ts = *evt.Timestamp
		}
		entries = append(entries, HistoryEntry{Kind: EntryAssistant, Speaker: agentName, Text: evt.Text, Timestamp: ts})
		if t.turn == nil {
			t.turn = newOpenTurn(ts)
		}
		t.turn.touch(evt.Timestamp)
	case daemon.EventNote:
		entries = t.settle(agentName)
		entries = append(entries, HistoryEntry{Kind: EntryNote, Text: evt.Text, Timestamp: time.Now().UnixMilli()})
	case daemon.EventError:
		entries = t.settle(agentName)
		entries = append(entries, HistoryEntry{Kind: EntryError, Text: evt.Text, Timestamp: time.Now().UnixMilli()})
		if t.turn != nil {
			t.turn.failed = true
			entries = append(entries, t.closeTurn(false)...)
		}
	case daemon.EventCompacted:
		entries = t.settle(agentName)
		entries = append(entries, HistoryEntry{
			Kind: EntryCompacted, Text: evt.Summary, Evicted: evt.Evicted,
			Strategy: evt.Strategy, Timestamp: time.Now().UnixMilli(),
		})
	case daemon.EventUsage:
		entries = t.settle(agentName)
	case daemon.EventInterrupted:
		entries = t.settle(agentName)
		if t.turn != nil {
			entries = append(entries, t.closeTurn(true)...)
		} else {
			entries = append(entries, HistoryEntry{Kind: EntryNote, Text: "stopped by you", Timestamp: time.Now().UnixMilli()})
		}
	}
	return entries
}

// A page boundary settles buffered text but does not finish the turn.
// History retention is applied by the caller.
func replayTranscript(events []daemon.StreamEvent, agentName string) []HistoryEntry {
	state := newTranscriptState()
	var entries []HistoryEntry
	for _, evt := range events {
		entries = append(entries, state.apply(evt, agentName)...)
		switch evt.Type {
		case daemon.EventReset:
			entries = nil
		case daemon.EventCommitted:
			for i := len(entries) - 1; i >= 0 && entries[i].Seq == 0; i-- {
				entries[i].Seq = evt.Seq
			}
		}
	}
	return append(entries, state.settle(agentName)...)
}

// openTurn follows the turn in flight until its signoff.
type openTurn struct {
	// Unix timestamps in milliseconds.
	start, last int64
	tools       int
	// A live turn ends now, rather than at its last replayed event.
	live   bool
	failed bool
}

func newOpenTurn(ts int64) *openTurn {
	if ts == 0 {
		ts = time.Now().UnixMilli()
	}
	return &openTurn{start: ts, last: ts}
}

func (t *openTurn) touch(ts *int64) {
	if ts != nil && *ts > t.last {
		t.last = *ts
	}
}

// An idle status racing the first event must not sign a turn off early.
func (t *openTurn) begun() bool {
	return t.live || t.tools > 0 || t.last > t.start
}

func (t *transcriptState) turnIsLive() {
	if t.turn == nil {
		t.turn = newOpenTurn(0)
	}
	t.turn.live = true
}

func (t *transcriptState) closeTurn(stopped bool) []HistoryEntry {
	turn := t.turn
	if turn == nil {
		return nil
	}
	t.turn, t.lastEvent = nil, time.Time{}
	end := turn.last
	if turn.live {
		end = max(end, time.Now().UnixMilli())
	}
	elapsed := end - turn.start
	return []HistoryEntry{{
		Kind: EntryTurnEnd, Mood: outcome(turn.failed, stopped, elapsed),
		ElapsedMs: elapsed, Tools: turn.tools, Timestamp: end,
	}}
}
