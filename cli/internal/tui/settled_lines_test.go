package tui

import (
	"fmt"
	"slices"
	"strings"
	"testing"
)

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
