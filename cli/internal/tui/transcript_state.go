package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"slices"
	"strings"
	"time"
)

// transcriptState buffers streamed entries and tracks the turn in progress.
type transcriptState struct {
	// Live thoughts are timed here; replayed thoughts carry daemon elapsed time.
	thinkingSince time.Time
	// Summarized thinking arrives after it is written, so its start is the last
	// live event other than thinking rather than its first received delta.
	lastEvent  time.Time
	turn       *openTurn
	activeKind ActiveStreamKind
	// Only the current update path appends to activeBuffer. Retained model
	// copies read activeText, whose bytes stay unchanged after each append.
	activeBuffer     *strings.Builder
	activeText       string
	thoughtMs        int64
	activeMessageID  string
	liveIDs          map[string]bool
	pendingCanonical *BoundedHistory
}

func newTranscriptState() transcriptState {
	return transcriptState{}
}

func (t *transcriptState) resetStream() {
	t.activeKind, t.activeText = StreamKindNone, ""
	t.activeBuffer = nil
	t.activeMessageID = ""
	t.liveIDs = nil
	t.pendingCanonical = nil
}

func (t transcriptState) activeEntryKind() EntryKind {
	if t.activeKind == StreamKindThinking {
		return EntryThinking
	}
	return EntryAssistant
}

func (t *transcriptState) settle(agentName string) []HistoryEntry {
	var entries []HistoryEntry
	if t.activeKind != StreamKindNone && t.activeText != "" {
		entry := HistoryEntry{
			MessageID: t.activeMessageID,
			Kind:      t.activeEntryKind(),
			Speaker:   agentName,
			Text:      strings.Clone(t.activeText),
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
	t.activeBuffer = nil
	t.activeMessageID = ""
	t.thinkingSince, t.thoughtMs = time.Time{}, 0
	return entries
}

func (t *transcriptState) streamDelta(kind ActiveStreamKind, text, agentName, messageID string) []HistoryEntry {
	if text == "" {
		return nil
	}
	t.turnIsLive()
	t.turn.answered = true
	var entries []HistoryEntry
	if t.activeKind != kind || t.activeMessageID != messageID {
		entries = t.settle(agentName)
		t.activeKind = kind
		t.activeMessageID = messageID
	}
	if t.activeBuffer == nil {
		t.activeBuffer = new(strings.Builder)
	}
	if messageID != "" {
		if t.liveIDs == nil {
			t.liveIDs = map[string]bool{}
		}
		t.liveIDs[messageID] = true
	}
	t.activeBuffer.WriteString(text)
	t.activeText = t.activeBuffer.String()
	if len(t.activeText) > MaxLiveStreamBytes {
		// One long thought splits into entries, each timed from its own start.
		watched := !t.thinkingSince.IsZero()
		entries = append(entries, t.settle(agentName)...)
		t.activeKind = kind
		t.activeMessageID = messageID
		if watched {
			t.thinkingSince = time.Now()
		}
	}
	return entries
}

// apply returns newly settled entries. The history owner stamps committed rows.
func (t *transcriptState) apply(evt daemon.StreamEvent, agentName string) []HistoryEntry {
	// Empty provider records and agent progress are observations, not replies.
	if evt.Type == daemon.EventMessage && evt.Text == "" || evt.Type == daemon.EventNote && evt.Source == "agent" {
		return nil
	}
	if evt.EntryID != "" && !evt.Replayed && len(t.liveIDs) > 0 && (evt.Type == daemon.EventMessage || evt.Type == daemon.EventThinking) {
		if t.pendingCanonical == nil {
			t.pendingCanonical = NewBoundedHistory(500, 2*1024*1024)
		}
		kind := EntryAssistant
		if evt.Type == daemon.EventThinking {
			kind = EntryThinking
		}
		entry := HistoryEntry{ID: evt.EntryID, Seq: evt.Position, Kind: kind, Speaker: agentName, Text: evt.Text, ElapsedMs: evt.ElapsedMs}
		if evt.Timestamp != nil {
			entry.Timestamp = *evt.Timestamp
		}
		if !t.pendingCanonical.Replace(entry) {
			t.pendingCanonical.Append(entry)
		}
		return nil
	}
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
	case daemon.EventCommitted:
		if evt.ReplacesAllLive || slices.Contains(evt.ReplacesLiveIDs, t.activeMessageID) {
			t.activeKind = StreamKindNone
			t.activeText = ""
			t.activeBuffer = nil
			t.activeMessageID = ""
			t.thinkingSince = time.Time{}
		}
		if evt.ReplacesAllLive {
			t.liveIDs = nil
		}
		for _, id := range evt.ReplacesLiveIDs {
			delete(t.liveIDs, id)
		}
		if t.pendingCanonical != nil {
			entries = append(entries, t.pendingCanonical.Entries()...)
			t.pendingCanonical = nil
		}
	case daemon.EventUser:
		entries = t.settle(agentName)
		speaker := inputSpeaker(evt)
		var ts int64
		if evt.Timestamp != nil && *evt.Timestamp > 0 {
			ts = *evt.Timestamp
		}
		// Your message closes the previous turn. Other sources open a turn
		// only when none is in flight.
		opens := t.turn == nil || evt.Source == "" || evt.Source == "chat"
		if opens {
			entries = append(entries, t.closeTurn(false)...)
		}
		entries = append(entries, HistoryEntry{
			Kind: EntryUser, ID: evt.EntryID, Seq: evt.Position, Source: evt.Source, MailKind: evt.MailKind, SenderSessionID: evt.SenderSessionID, Speaker: speaker, Text: evt.Text,
			Timestamp: ts,
		})
		if opens {
			t.turn = newOpenTurn(ts)
		}
	case daemon.EventText:
		entries = t.streamDelta(StreamKindText, evt.Text, agentName, evt.MessageID)
	case daemon.EventThinking:
		if evt.EntryID != "" {
			entries = t.settle(agentName)
			entries = append(entries, HistoryEntry{ID: evt.EntryID, Seq: evt.Position, Kind: EntryThinking, Speaker: agentName, Text: evt.Text, ElapsedMs: evt.ElapsedMs})
			break
		}
		if t.activeKind != StreamKindThinking || t.activeMessageID != evt.MessageID {
			entries = t.settle(agentName)
			t.activeKind = StreamKindThinking
			t.activeMessageID = evt.MessageID
			if !evt.Replayed {
				t.thinkingSince = thoughtStart
			}
		}
		if evt.ElapsedObserved && !evt.Replayed {
			t.thinkingSince = time.Time{}
			t.thoughtMs = evt.ElapsedMs
		} else {
			t.thoughtMs += evt.ElapsedMs
		}
		entries = append(entries, t.streamDelta(StreamKindThinking, evt.Text, agentName, evt.MessageID)...)
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
			Kind: EntryTool, ID: evt.EntryID, Seq: evt.Position, ToolName: evt.ToolName, ToolArgs: evt.ToolArgs,
			ToolResult: evt.ToolResult, ToolTrace: evt.ToolTrace,
			Timestamp: time.Now().UnixMilli(),
		})
		if t.turn == nil {
			t.turn = newOpenTurn(0)
		}
		t.turn.tools++
		t.turn.touch(evt.Timestamp)
	case daemon.EventMessage:
		entries = t.settle(agentName)
		var ts int64
		if evt.Timestamp != nil && *evt.Timestamp > 0 {
			ts = *evt.Timestamp
		}
		entries = append(entries, HistoryEntry{Kind: EntryAssistant, ID: evt.EntryID, Seq: evt.Position, Speaker: agentName, Text: evt.Text, Timestamp: ts})
		if t.turn == nil {
			t.turn = newOpenTurn(ts)
		}
		t.turn.answered = true
		t.turn.touch(evt.Timestamp)
	case daemon.EventNote:
		entries = t.settle(agentName)
		entries = append(entries, HistoryEntry{Kind: EntryNote, ID: evt.EntryID, Seq: evt.Position, Text: evt.Text, Timestamp: time.Now().UnixMilli()})
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
			Kind: EntryCompacted, ID: evt.EntryID, Seq: evt.Position, Text: evt.Summary, Evicted: evt.Evicted,
			Strategy: evt.Strategy, Timestamp: time.Now().UnixMilli(),
		})
	case daemon.EventUsage:
		entries = t.settle(agentName)
	case daemon.EventTurnCompleted:
		entries = t.settle(agentName)
		if t.turn != nil {
			t.turn.failed = t.turn.failed || evt.Source == "failed"
			entries = append(entries, t.closeTurn(evt.Source == "interrupted")...)
		}
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
				if entries[i].MessageID == "" {
					entries[i].Seq = evt.Seq
				}
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
	// answered is whether the agent wrote anything; a turn opened by a note
	// it never answered has nothing to sign off.
	answered bool
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
	if !turn.answered && turn.tools == 0 && !turn.failed && !stopped {
		return nil
	}
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

func inputSpeaker(evt daemon.StreamEvent) string {
	if evt.Source == "mail" {
		return cmp.Or(evt.Speaker, "Agent")
	}
	if evt.Source == "" || evt.Source == "chat" {
		return "You"
	}
	return evt.Source
}
