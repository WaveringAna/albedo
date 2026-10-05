package tui

import (
	"albedo/cli/internal/daemon"
	"encoding/json"
	"fmt"
	"slices"
)

type EntryKind string

const (
	EntryUser      EntryKind = "user"
	EntryAssistant EntryKind = "assistant"
	EntryThinking  EntryKind = "thinking"
	EntryTool      EntryKind = "tool"
	EntryNote      EntryKind = "note"
	EntryError     EntryKind = "error"
	EntryCompacted EntryKind = "compacted"
	// EntryTurnEnd closes a turn with its outcome, length, and tool count.
	EntryTurnEnd EntryKind = "turn_end"
)

type HistoryEntry struct {
	MessageID       string
	ID              string
	Source          string
	MailKind        string
	SenderSessionID string
	ToolArgs        map[string]any
	// facts is what this entry contributes to a grouped row, computed once
	// when the entry settles. Targets stay as recorded; naming is at render.
	facts      *entryFacts
	ToolTrace  *daemon.ToolTrace
	Speaker    string
	Mood       mood
	Text       string
	ToolName   string
	ToolResult string
	// Strategy is the compaction strategy that produced a compacted entry.
	Strategy  string
	Kind      EntryKind
	Timestamp int64
	SizeBytes int64
	Evicted   int
	Tools     int
	// Pending is a message of yours the daemon has not echoed back yet.
	Pending   pending
	ElapsedMs int64
	// Seq is the newest transcript row this entry came from; 0 until a
	// `committed` event says which rows cover it.
	Seq int64
	// Live is a reply still streaming in. It renders on every token, so it
	// skips the second rendering that marks wraps for a copy until it settles.
	Live bool
}

// pending records whether a user message is awaiting admission, queued for
// delivery, or unresolved after its operation receipt expires.
type pending int

const (
	settled pending = iota
	sending
	queued
	unresolved
)

func (e *HistoryEntry) ComputeSize() int64 {
	size := int64(len(e.ID) + len(e.MessageID) + len(e.Source) + len(e.MailKind) + len(e.SenderSessionID) + len(e.Speaker) + len(e.Text) + len(e.ToolName) + len(e.ToolResult) + 64)
	for k, v := range e.ToolArgs {
		size += int64(len(k) + 16)
		switch val := v.(type) {
		case string:
			size += int64(len(val))
		default:
			data, _ := json.Marshal(val)
			size += int64(len(data))
		}
	}
	if e.ToolTrace != nil {
		for _, act := range e.ToolTrace.Activities {
			size += int64(len(act.Kind) + len(act.Target) + len(act.Detail) + 16)
		}
		for _, ch := range e.ToolTrace.Changes {
			size += int64(len(ch.Path) + len(ch.Kind) + len(ch.Diff) + len(ch.Reason) + 32)
		}
	}
	e.SizeBytes = size
	return size
}

type BoundedHistory struct {
	entries        []HistoryEntry
	MaxEntries     int
	MaxBytes       int64
	totalBytes     int64
	evictedEntries int
	evictedBytes   int64
	// evictedThrough is the newest transcript row among evicted entries: the
	// daemon holds everything up to it, and older pages resume after it.
	evictedThrough int64
}

func NewBoundedHistory(maxEntries int, maxBytes int64) *BoundedHistory {
	if maxEntries <= 0 {
		maxEntries = 500
	}
	if maxBytes <= 0 {
		maxBytes = 2 * 1024 * 1024
	}
	return &BoundedHistory{
		MaxEntries: maxEntries,
		MaxBytes:   maxBytes,
		entries:    make([]HistoryEntry, 0, 128),
	}
}

func (h *BoundedHistory) Len() int                { return len(h.entries) }
func (h *BoundedHistory) TotalBytes() int64       { return h.totalBytes }
func (h *BoundedHistory) EvictedCount() int       { return h.evictedEntries }
func (h *BoundedHistory) EvictedBytes() int64     { return h.evictedBytes }
func (h *BoundedHistory) Entries() []HistoryEntry { return h.entries }

func (h *BoundedHistory) TruncationNotice() string {
	if h.evictedEntries > 0 {
		return fmt.Sprintf("[%d older messages hidden (%d KB); full history is saved by Albedo]", h.evictedEntries, h.evictedBytes/1024)
	}
	return ""
}

// EvictedThrough is the newest transcript row among evicted entries, or 0.
func (h *BoundedHistory) EvictedThrough() int64 {
	return h.evictedThrough
}

// Stamp marks the trailing entries no row covered yet as covered by seq.
func (h *BoundedHistory) Stamp(seq int64) {
	for i := len(h.entries) - 1; i >= 0 && h.entries[i].Seq == 0; i-- {
		if h.entries[i].MessageID == "" {
			h.entries[i].Seq = seq
		}
	}
}

func (h *BoundedHistory) Find(id string) int {
	if id == "" {
		return -1
	}
	return slices.IndexFunc(h.entries, func(entry HistoryEntry) bool { return entry.ID == id })
}

func (h *BoundedHistory) Replace(entry HistoryEntry) bool {
	index := h.Find(entry.ID)
	if index < 0 {
		return false
	}
	entry.ComputeSize()
	h.totalBytes += entry.SizeBytes - h.entries[index].SizeBytes
	h.entries[index] = entry
	h.enforceBounds()
	return true
}

// Prepend puts older entries before the retained ones. It does not evict:
// they were asked for, and the next Append trims as usual.
func (h *BoundedHistory) Prepend(older []HistoryEntry) {
	if len(older) == 0 {
		return
	}
	unique := make([]HistoryEntry, 0, len(older))
	seen := map[string]bool{}
	for _, entry := range h.entries {
		if entry.ID != "" {
			seen[entry.ID] = true
		}
	}
	for _, entry := range older {
		if entry.ID != "" && seen[entry.ID] {
			continue
		}
		if entry.ID != "" {
			seen[entry.ID] = true
		}
		h.totalBytes += entry.ComputeSize()
		unique = append(unique, entry)
	}
	h.entries = slices.Concat(unique, h.entries)
	h.evictedThrough = 0
}

func (h *BoundedHistory) enforceBounds() {
	for len(h.entries) > 0 && (len(h.entries) > h.MaxEntries || h.totalBytes > h.MaxBytes) {
		h.evictFirst()
		// A row's entries leave together, so re-reading from the next row
		// never repeats what is still shown.
		for seq := h.evictedThrough; seq > 0 && len(h.entries) > 0 && h.entries[0].Seq == seq; {
			h.evictFirst()
		}
	}
}

func (h *BoundedHistory) evictFirst() {
	removed := h.entries[0]
	h.entries[0] = HistoryEntry{} // Explicitly zero out evicted slot to drop GC references
	h.entries = h.entries[1:]
	h.totalBytes = max(0, h.totalBytes-removed.SizeBytes)
	h.evictedEntries++
	h.evictedBytes += removed.SizeBytes
	h.evictedThrough = max(h.evictedThrough, removed.Seq)
}

func (h *BoundedHistory) Append(entry HistoryEntry) {
	entry.ComputeSize()
	h.entries = append(h.entries, entry)
	h.totalBytes += entry.SizeBytes
	h.enforceBounds()
}

func (h *BoundedHistory) Clear() {
	clear(h.entries)
	*h = BoundedHistory{MaxEntries: h.MaxEntries, MaxBytes: h.MaxBytes, entries: h.entries[:0]}
}

// Retire provisional chunks without counting them as hidden durable history.
func (h *BoundedHistory) retireLive(ids []string, all bool) bool {
	removed := false
	h.entries = slices.DeleteFunc(h.entries, func(entry HistoryEntry) bool {
		retire := entry.MessageID != "" && (all || slices.Contains(ids, entry.MessageID))
		if retire {
			h.totalBytes -= entry.SizeBytes
			removed = true
		}
		return retire
	})
	return removed
}
