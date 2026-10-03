// These tests catch mutable live-buffer ownership and chunk-boundary
// regressions, and signoffs placed by event order. Daemon E2E cannot retain Go
// model copies, control the exact delta boundaries received by the terminal,
// or see rows. Copies here are retained readers; only the current update path
// appends, settles, or discards live text.
package tui

import (
	"slices"
	"strings"
	"testing"
	"unsafe"

	"albedo/cli/internal/daemon"
)

func TestObservedZeroThinkingDurationStopsLocalClock(t *testing.T) {
	state := newTranscriptState()
	state.apply(daemon.StreamEvent{Type: daemon.EventThinking, Text: "thought"}, "agent")
	if state.thinkingSince.IsZero() {
		t.Fatal("live thought did not start its local clock")
	}
	state.apply(daemon.StreamEvent{Type: daemon.EventThinking, ElapsedObserved: true, ElapsedMs: 0}, "agent")
	if !state.thinkingSince.IsZero() || state.thoughtMs != 0 {
		t.Fatal("observed zero duration was treated as an unknown duration")
	}
}

// Completion is a separate canonical observation; the server sends no
// synthetic interrupted event. It must settle the live tail and close the
// turn once, including its stopped/failed footer.
func TestCanonicalCompletionSettlesAndClosesLiveTurn(t *testing.T) {
	for _, source := range []string{"", "interrupted", "failed"} {
		t.Run(source, func(t *testing.T) {
			state := newTranscriptState()
			state.apply(daemon.StreamEvent{Type: daemon.EventUser, Text: "question", Source: "chat"}, "agent")
			state.apply(daemon.StreamEvent{Type: daemon.EventText, Text: "answer"}, "agent")
			entries := state.apply(daemon.StreamEvent{Type: daemon.EventTurnCompleted, Source: source}, "agent")
			if state.turn != nil || state.activeText != "" || len(entries) != 2 || entries[0].Kind != EntryAssistant || entries[0].Text != "answer" || entries[1].Kind != EntryTurnEnd {
				t.Fatalf("completion did not settle and close the turn: %#v", entries)
			}
			if source == "interrupted" && entries[1].Mood != moodStopped || source == "failed" && entries[1].Mood != moodFailed {
				t.Fatalf("completion lost its terminal outcome: %#v", entries[1])
			}
			if repeated := state.apply(daemon.StreamEvent{Type: daemon.EventTurnCompleted, Source: source}, "agent"); len(repeated) != 0 {
				t.Fatalf("repeated completion created a duplicate footer: %#v", repeated)
			}
		})
	}
}

func TestChatModelSnapshotsAndHistoryOwnTheirText(t *testing.T) {
	model := newTestChatModel(t, &daemon.Session{ID: "snapshot"})
	model.SetSize(80, 24)
	appendThought := func(text string) {
		model, _ = model.Update(ChatStreamEventMsg{
			SessionID: model.SessionID, Generation: model.Generation,
			Event: daemon.StreamEvent{Type: daemon.EventThinking, Text: text},
		})
	}
	appendThought("old thought")
	retained := model
	oldThought := retained.renderThought()
	appendThought(" continued")
	continued := model
	appendThought(strings.Repeat(" extended", 1024))
	if retained.transcript.activeText != "old thought" || retained.renderThought() != oldThought || continued.transcript.activeText != "old thought continued" {
		t.Fatal("append or growth changed a retained snapshot")
	}
	liveText := model.transcript.activeText
	model, _ = model.Update(ChatStreamEventMsg{
		SessionID: model.SessionID, Generation: model.Generation,
		Event: daemon.StreamEvent{Type: daemon.EventUsage},
	})
	history := model.History.Entries()
	if len(history) != 1 || history[0].Text != liveText {
		t.Fatal("settlement lost the live text")
	}
	// Equal bytes alone cannot detect history retaining the buffer's spare capacity.
	if unsafe.StringData(history[0].Text) == unsafe.StringData(liveText) {
		t.Fatal("settled history shares live-buffer storage")
	}
	if model.transcript.activeBuffer != nil || model.transcript.activeText != "" {
		t.Fatal("settlement retained the live buffer")
	}
	appendThought("replacement")
	if retained.transcript.activeText != "old thought" || history[0].Text != liveText {
		t.Fatal("new stream changed a retained snapshot or settled history")
	}
}

func TestTranscriptDiscardPreservesRetainedReaders(t *testing.T) {
	for _, eventType := range []daemon.EventType{daemon.EventRetry, daemon.EventReset} {
		t.Run(string(eventType), func(t *testing.T) {
			state := newTranscriptState()
			state.apply(daemon.StreamEvent{Type: daemon.EventText, Text: "discarded"}, "agent")
			retained := state
			if entries := state.apply(daemon.StreamEvent{Type: eventType}, "agent"); len(entries) != 0 {
				t.Fatalf("discard settled %d entries", len(entries))
			}
			if state.activeBuffer != nil || state.activeText != "" || state.activeKind != StreamKindNone {
				t.Fatal("discard retained live buffer ownership")
			}
			state.apply(daemon.StreamEvent{Type: daemon.EventText, Text: "fresh"}, "agent")
			entries := state.apply(daemon.StreamEvent{Type: daemon.EventMessage, Text: "fresh"}, "agent")
			if retained.activeText != "discarded" || len(entries) != 1 || entries[0].Text != "fresh" {
				t.Fatal("discard changed a retained reader or failed to reset message deduplication")
			}
		})
	}
}

func TestTranscriptSplitsStrictlyAfterAppendingPastLimit(t *testing.T) {
	for _, eventType := range []daemon.EventType{daemon.EventText, daemon.EventThinking} {
		t.Run(string(eventType), func(t *testing.T) {
			state := newTranscriptState()
			atLimit := strings.Repeat("a", MaxLiveStreamBytes)
			entries := state.apply(daemon.StreamEvent{Type: eventType, Text: atLimit}, "agent")
			if len(entries) != 0 || state.activeText != atLimit || state.activeBuffer == nil {
				t.Fatal("stream settled at exactly the byte limit")
			}
			retained := state
			entries = state.apply(daemon.StreamEvent{Type: eventType, Text: "b"}, "agent")
			if len(entries) != 1 || entries[0].Text != atLimit+"b" || retained.activeText != atLimit {
				t.Fatal("crossing split omitted the final delta or changed a retained reader")
			}
			if state.activeBuffer != nil || state.activeText != "" || state.activeKind != retained.activeKind {
				t.Fatal("automatic settlement did not drop the buffer and retain stream kind")
			}
			oversized := strings.Repeat("c", MaxLiveStreamBytes*2+1)
			entries = state.apply(daemon.StreamEvent{Type: eventType, Text: oversized}, "agent")
			if len(entries) != 1 || entries[0].Text != oversized || state.activeBuffer != nil || state.activeText != "" {
				t.Fatal("oversized delta was split internally or retained a live buffer")
			}
		})
	}
}

func TestTranscriptMessageDeduplicationSpansSettlements(t *testing.T) {
	state := newTranscriptState()
	first := strings.Repeat("a", MaxLiveStreamBytes+1)
	second := "second"
	var history []HistoryEntry
	history = append(history, state.apply(daemon.StreamEvent{Type: daemon.EventText, Text: first}, "agent")...)
	history = append(history, state.apply(daemon.StreamEvent{Type: daemon.EventThinking, Text: "thought"}, "agent")...)
	history = append(history, state.apply(daemon.StreamEvent{Type: daemon.EventText, Text: second}, "agent")...)
	history = append(history, state.apply(daemon.StreamEvent{Type: daemon.EventUsage}, "agent")...)
	if entries := state.apply(daemon.StreamEvent{Type: daemon.EventMessage, Text: first + second}, "agent"); len(entries) != 0 {
		t.Fatal("committed message duplicated text settled across multiple boundaries")
	}
	if len(history) != 3 || history[0].Text != first || history[1].Text != "thought" || history[2].Text != second {
		t.Fatal("multiple settlements lost or reordered history")
	}
	entries := state.apply(daemon.StreamEvent{Type: daemon.EventMessage, Text: first + second}, "agent")
	if len(entries) != 1 || entries[0].Text != first+second {
		t.Fatal("deduplication did not reset after the committed message")
	}
}

func TestANoteTheAgentNeverAnsweredHasNoSignoff(t *testing.T) {
	// /link and /work queue a note; it commits right before your next message.
	entries := replayTranscript([]daemon.StreamEvent{
		{Type: daemon.EventUser, Source: "links", Text: "linked with chernobog:~/proj/albedo", Replayed: true},
		{Type: daemon.EventUser, Source: "chat", Text: "hi", Replayed: true},
		{Type: daemon.EventMessage, Text: "hello", Replayed: true},
	}, "albedo")
	var kinds []EntryKind
	for _, entry := range entries {
		kinds = append(kinds, entry.Kind)
	}
	if want := []EntryKind{EntryUser, EntryUser, EntryAssistant}; !slices.Equal(kinds, want) {
		t.Fatalf("entries %v, want %v", kinds, want)
	}
}
