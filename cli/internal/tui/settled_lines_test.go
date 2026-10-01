// Trimming must release old descriptors without clearing surviving text.
// Daemon E2E cannot inspect the TUI's retained memory.
package tui

import (
	"fmt"
	"slices"
	"strings"
	"testing"
)

func TestTrimSettledLinesReleasesDescriptors(t *testing.T) {
	for _, test := range []struct {
		name string
		rows []string
		kept int
	}{
		{name: "row cap", rows: slices.Repeat([]string{"│ short"}, MaxSettledLines+3), kept: MaxSettledLines},
		{name: "byte cap", rows: slices.Repeat([]string{"│ " + strings.Repeat("x", 512)}, 600), kept: MaxSettledLinesBytes / (len("│ ") + 512 + 3)},
		{name: "all rows", rows: []string{"small", strings.Repeat("x", MaxSettledLinesBytes+1)}, kept: 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			// Fixed-width suffixes make survivor ordering observable.
			for i := range test.rows {
				test.rows[i] += fmt.Sprintf("%03d", i)
			}
			old := test.rows
			want := slices.Clone(old[len(old)-test.kept:])
			m := ChatModel{Follow: true, settledLines: old, settledLinesBytes: rowBytes(old)}
			m.trimSettledLines()
			if !slices.Equal(m.settledLines, want) || m.settledLinesBytes != rowBytes(want) || m.droppedSettledLines != len(old)-test.kept {
				t.Fatalf("survivors=%d bytes=%d dropped=%d", len(m.settledLines), m.settledLinesBytes, m.droppedSettledLines)
			}
			for i, row := range old {
				if row != "" {
					t.Fatalf("old descriptor %d still holds text", i)
				}
			}
			if len(want) > 0 {
				old[len(old)-1] = "changed old slice"
				if !slices.Equal(m.settledLines, want) {
					t.Fatal("survivors share the old descriptor slice")
				}
			}
		})
	}
}

func BenchmarkTrimSettledLinesFullDisplay(b *testing.B) {
	for _, width := range []int{80, 512} {
		b.Run(fmt.Sprintf("ascii%d", width), func(b *testing.B) {
			row := "│ " + strings.Repeat("x", width)
			count := min(MaxSettledLines, MaxSettledLinesBytes/len(row))
			m := ChatModel{Follow: true, settledLines: slices.Repeat([]string{row}, count), settledLinesBytes: int64(count * len(row))}
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				m.settledLines = append(m.settledLines, row)
				m.settledLinesBytes += int64(len(row))
				m.trimSettledLines()
			}
		})
	}
}
