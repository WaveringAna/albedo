// Byte-bound eviction protects long TUI transcripts beyond practical daemon E2E history.
package tui

import (
	"strings"
	"testing"
)

func TestBoundedHistory_ByteLimit(t *testing.T) {
	h := NewBoundedHistory(100, 500)
	for range 10 {
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
