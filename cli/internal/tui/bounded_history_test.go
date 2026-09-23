package tui

import (
	"strings"
	"testing"
)

func TestBoundedHistory_EntryCountLimit(t *testing.T) {
	h := NewBoundedHistory(5, 1000000)
	for i := 0; i < 10; i++ {
		h.Append(HistoryEntry{
			Kind: EntryUser,
			Text: "message",
		})
	}

	if h.Len() != 5 {
		t.Fatalf("expected 5 entries, got %d", h.Len())
	}
	if h.EvictedCount() != 5 {
		t.Fatalf("expected 5 evicted, got %d", h.EvictedCount())
	}
	notice := h.TruncationNotice()
	if !strings.Contains(notice, "5 older messages truncated") {
		t.Fatalf("expected truncation notice, got: %s", notice)
	}
}

func TestBoundedHistory_ByteLimit(t *testing.T) {
	h := NewBoundedHistory(100, 500)
	for i := 0; i < 10; i++ {
		h.Append(HistoryEntry{
			Kind: EntryAssistant,
			Text: strings.Repeat("x", 100),
		})
	}

	if h.TotalBytes() > 500 {
		t.Fatalf("expected total bytes <= 500, got %d", h.TotalBytes())
	}
	if h.EvictedCount() == 0 {
		t.Fatalf("expected evictions due to byte limit")
	}
	if h.EvictedBytes() == 0 {
		t.Fatalf("expected non-zero evicted bytes")
	}
}

func TestBoundedHistory_ToolArgsComputeSize(t *testing.T) {
	entryWithoutArgs := HistoryEntry{
		Kind:     EntryTool,
		ToolName: "test_tool",
	}
	size1 := entryWithoutArgs.ComputeSize()

	entryWithArgs := HistoryEntry{
		Kind:     EntryTool,
		ToolName: "test_tool",
		ToolArgs: map[string]any{
			"command": "echo hello",
			"count":   42,
		},
	}
	size2 := entryWithArgs.ComputeSize()

	if size2 <= size1 {
		t.Fatalf("expected size with ToolArgs (%d) to be greater than without (%d)", size2, size1)
	}
}

func TestBoundedHistory_ClearZeroesSlots(t *testing.T) {
	h := NewBoundedHistory(10, 100000)
	h.Append(HistoryEntry{Kind: EntryUser, Text: "sample text"})
	if h.Len() != 1 {
		t.Fatalf("expected 1 entry")
	}

	h.Clear()
	if h.Len() != 0 {
		t.Fatalf("expected 0 entries after clear")
	}
	if h.TotalBytes() != 0 {
		t.Fatalf("expected 0 total bytes after clear, got %d", h.TotalBytes())
	}
}
