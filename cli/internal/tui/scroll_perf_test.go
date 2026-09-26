package tui

import (
	"albedo/cli/internal/daemon"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"runtime"
	"runtime/debug"
	"sort"
	"sync"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/mattn/go-isatty"
)

// Fixture generators for dense markdown, fenced code, multi-file diffs, CJK, and ANSI.

func generateMarkdownFixture() string {
	return `### Architectural Invariants: Concurrent Scrollback Engine

When optimizing the **TUI terminal pipeline**, several critical invariants must hold:
1. *Zero mutation* during read passes.
2. Direct index slicing rather than linear allocations where possible.
3. Strict bounds enforcement against memory leaks.

> "Premature optimization is the root of all evil, but unmeasured scrolling latency destroys user trust faster than functional bugs."

| Subsystem | Target Latency | Budget (120Hz) | Budget (60Hz) |
| :--- | :--- | :--- | :--- |
| Update (State) | < 0.50 ms | 8.33 ms | 16.67 ms |
| View (Diff/Format) | < 3.00 ms | 8.33 ms | 16.67 ms |
| Emission (PTY) | < 2.00 ms | 8.33 ms | 16.67 ms |
`
}

func generateFencedCodeFixture() string {
	return `Here is the concurrent ring buffer implementation in Rust:

` + "```go" + `
package ringbuf

import "sync/atomic"

type RingBuffer[T any] struct {
	buffer []T
	head   atomic.Uint64
	tail   atomic.Uint64
	mask   uint64
}

func NewRingBuffer[T any](size int) *RingBuffer[T] {
	return &RingBuffer[T]{buffer: make([]T, size), mask: uint64(size - 1)}
}
` + "```" + `

And the consumer routine:

` + "```py" + `
class BatchProcessor:
    def __init__(self, capacity: int):
        self.capacity = capacity
        self.queue = []

    async def drain(self) -> list:
        items = list(self.queue)
        self.queue.clear()
        return items
` + "```"
}

func generateMultiFileToolTrace() *daemon.ToolTrace {
	diff1 := `@@ -370,12 +370,18 @@ func (m *ChatModel) refreshViewportContent() {
-	m.scrollOffset = max(0, min(m.scrollOffset, maxScroll))
-	end := min(totalLines, m.scrollOffset+vpHeight)
-	if m.scrollOffset < end {
-		visibleSlice = allLines[m.scrollOffset:end]
-	}
+	start := clamp(m.scrollOffset, 0, maxScroll)
+	end := clamp(start+vpHeight, start, totalLines)
+	visibleSlice = allLines[start:end]
+	m.Viewport.SetContent(strings.Join(visibleSlice, "
"))
@@ -485,6 +491,10 @@ func (m ChatModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
+		case tea.KeyPgUp:
+			m.scrollOffset = max(0, m.scrollOffset-m.Viewport.Height)
+			m.refreshViewportContent()
+			return m, nil`

	diff2 := `@@ -65,6 +65,12 @@ func (r TranscriptRenderer) RenderToolTrace
+	if flags.Diffs {
+		b.WriteString(r.RenderDiff(ch.Diff, width))
+	}`

	return &daemon.ToolTrace{
		Activities: []daemon.ToolActivity{
			{Kind: "search", Target: "refreshViewportContent"},
			{Kind: "read", Target: "cli/internal/tui/chat.go"},
			{Kind: "diff", Target: "git diff HEAD"},
		},
		Changes: []daemon.FileChange{
			{
				Path:    "cli/internal/tui/chat.go",
				Kind:    "diff",
				Added:   12,
				Removed: 5,
				Diff:    diff1,
			},
			{
				Path:    "cli/internal/tui/transcript.go",
				Kind:    "diff",
				Added:   6,
				Removed: 0,
				Diff:    diff2,
			},
		},
	}
}

func generateCJKFixture() string {
	return `## 多言語表示・端末セル幅検証 (CJK Width & Unicode uniseg)

日本語の長いテキスト：
吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。吾輩はここで始めて人間というものを見た。

中文测试段落：
道可道，非常道。名可名，非常名。无名天地之始；有名万物之母。故常无欲，以观其妙；常有欲，以观其徼。此两者，同出而异名，同谓之玄。

한국어 성능 테스트 문場:
동해 물과 백두산이 마르고 닳도록 하느님이 보우하사 우리나라 만세. 무궁화 삼천리 화려 강산 대한 사람 대한으로 길이 보전하세.
`
}

func generateAnsiFixture() string {
	return "\x1b[38;5;196m[FATAL ERROR]\x1b[0m \x1b[1;33mExecution halted:\x1b[0m check /var/log/kernel.log for details.\n" +
		"\x1b[38;5;46m[SUCCESS]\x1b[0m \x1b[32mRendered\x1b[0m 1024 frames in 8.12ms (123.15 Hz).\n" +
		"\x1b[38;5;39m[INFO]\x1b[0m Memory stable at 4.2MB heap in-use.\n"
}

// buildRealisticHistory populates ChatModel with entries exceeding MaxSettledLines
// and MaxSettledLinesBytes with fully expanded flags and deterministic timestamps.
func buildRealisticHistory(m *ChatModel) (appendedCount int, totalBytesAppended int64) {
	// Enable ALL visual elements to guarantee worst-case rendering complexity
	m.Flags = DisplayFlags{
		Thinking:   true,
		Tools:      true,
		Diffs:      true,
		Compaction: true,
	}

	fixtures := []struct {
		kind EntryKind
		text string
	}{
		{EntryUser, "Show me the architectural diff for the scrollback engine, fenced code, and include CJK tests."},
		{EntryThinking, "Analyzing viewport slice performance, rune width metrics, and ANSI diffing overhead across viewports..."},
		{EntryAssistant, generateMarkdownFixture()},
		{EntryTool, "Executed git diff with multi-file inspection"},
		{EntryAssistant, generateFencedCodeFixture()},
		{EntryAssistant, generateCJKFixture()},
		{EntryNote, generateAnsiFixture()},
		{EntryCompacted, "Historical conversation summary checkpoint"},
	}

	// Deterministic base timestamp in milliseconds (2024-03-10 12:00:00 UTC)
	baseTimestampMs := int64(1710072000000)

	for {
		item := fixtures[appendedCount%len(fixtures)]
		entry := HistoryEntry{
			Kind:      item.kind,
			Speaker:   "albedo",
			Text:      fmt.Sprintf("[%d] %s", appendedCount+1, item.text),
			Timestamp: baseTimestampMs + int64(appendedCount*60000), // fixed deterministic 1-minute increments
		}
		if item.kind == EntryTool {
			entry.ToolName = "git_diff"
			entry.ToolTrace = generateMultiFileToolTrace()
			entry.ToolResult = "diff complete: 2 files changed, 18 insertions(+), 5 deletions(-)"
		}

		m.appendSettledEntry(entry)
		appendedCount++
		totalBytesAppended += int64(len(entry.Text))

		// Stop when history has exceeded the retention bounds and dropped lines
		if m.droppedSettledLines > 0 && len(m.settledLines) >= MaxSettledLines {
			break
		}
		if appendedCount > 500 {
			break
		}
	}
	return appendedCount, totalBytesAppended
}

type LatencyDistribution struct {
	Count       int           `json:"count"`
	Min         time.Duration `json:"min_ns"`
	Mean        time.Duration `json:"mean_ns"`
	Median      time.Duration `json:"p50_ns"`
	P90         time.Duration `json:"p90_ns"`
	P95         time.Duration `json:"p95_ns"`
	P99         time.Duration `json:"p99_ns"`
	Max         time.Duration `json:"max_ns"`
	StdDev      time.Duration `json:"stddev_ns"`
	PctUnder120 float64       `json:"pct_under_120hz"`
	PctUnder60  float64       `json:"pct_under_60hz"`
}

func calcDistribution(samples []time.Duration) LatencyDistribution {
	n := len(samples)
	if n == 0 {
		return LatencyDistribution{}
	}
	sorted := make([]time.Duration, n)
	copy(sorted, samples)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })

	var sum int64
	var under120, under60 int
	budget120 := 8333333 * time.Nanosecond
	budget60 := 16666667 * time.Nanosecond

	for _, s := range sorted {
		sum += int64(s)
		if s <= budget120 {
			under120++
		}
		if s <= budget60 {
			under60++
		}
	}
	mean := time.Duration(sum / int64(n))

	var varianceSum float64
	for _, s := range sorted {
		diff := float64(s - mean)
		varianceSum += diff * diff
	}
	stdDev := time.Duration(math.Sqrt(varianceSum / float64(n)))

	p := func(pct float64) time.Duration {
		idx := int(float64(n-1) * pct)
		return sorted[idx]
	}

	return LatencyDistribution{
		Count:       n,
		Min:         sorted[0],
		Mean:        mean,
		Median:      p(0.50),
		P90:         p(0.90),
		P95:         p(0.95),
		P99:         p(0.99),
		Max:         sorted[n-1],
		StdDev:      stdDev,
		PctUnder120: float64(under120) * 100.0 / float64(n),
		PctUnder60:  float64(under60) * 100.0 / float64(n),
	}
}

type ScenarioResult struct {
	Name                      string              `json:"name"`
	Width                     int                 `json:"width"`
	Height                    int                 `json:"height"`
	Streaming                 bool                `json:"streaming"`
	RetainedLines             int                 `json:"retained_lines"`
	RetainedBytes             int64               `json:"retained_bytes"`
	DroppedLines              int                 `json:"dropped_lines"`
	AppendedEntries           int                 `json:"appended_entries"`
	UniqueViewHashes          int                 `json:"unique_view_hashes"`
	UniqueOffsetsVisited      int                 `json:"unique_offsets_visited"`
	TotalScrollSteps          int                 `json:"total_scroll_steps"`
	MovingSteps               int                 `json:"moving_steps"`
	ContentChangedSteps       int                 `json:"content_changed_steps"`
	MovingFrameRatio          float64             `json:"moving_frame_ratio"`
	ContentChangeRatio        float64             `json:"content_change_ratio"`
	NonVacuous                bool                `json:"non_vacuous"`
	ScrollUpdateLatencies     LatencyDistribution `json:"scroll_update_latencies"`
	StreamUpdateLatencies     LatencyDistribution `json:"stream_update_latencies,omitempty"`
	ViewLatencies             LatencyDistribution `json:"view_latencies"`
	PureScrollLatencies       LatencyDistribution `json:"pure_scroll_latencies"`
	InterleavedFrameLatencies LatencyDistribution `json:"interleaved_frame_latencies,omitempty"`
	PrimaryGateLatencies      LatencyDistribution `json:"primary_gate_latencies"`
	Passes120HzGate           bool                `json:"passes_120hz_gate"`
	GateReason                string              `json:"gate_reason"`
	AllocsPerOp               uint64              `json:"allocs_per_op"`
	BytesPerOp                uint64              `json:"bytes_per_op"`
}

type MemorySnapshot struct {
	AllocBytes      uint64 `json:"alloc_bytes"`
	TotalAllocBytes uint64 `json:"total_alloc_bytes"`
	SysBytes        uint64 `json:"sys_bytes"`
	HeapAllocBytes  uint64 `json:"heap_alloc_bytes"`
	HeapInuseBytes  uint64 `json:"heap_inuse_bytes"`
	NumGC           uint32 `json:"num_gc"`
	PauseTotalNs    uint64 `json:"pause_total_ns"`
}

func readMem() MemorySnapshot {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	return MemorySnapshot{
		AllocBytes:      m.Alloc,
		TotalAllocBytes: m.TotalAlloc,
		SysBytes:        m.Sys,
		HeapAllocBytes:  m.HeapAlloc,
		HeapInuseBytes:  m.HeapInuse,
		NumGC:           m.NumGC,
		PauseTotalNs:    m.PauseTotalNs,
	}
}

func hashString(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:8])
}

func runScrollScenario(width, height int, streaming bool, sampleCount int) ScenarioResult {
	session := &daemon.Session{ID: "perf-bench-sess", Workspace: "/workspace/bench"}
	m := NewChatModel(session, nil)
	m.SetSize(width, height)

	appendedCount, _ := buildRealisticHistory(&m)

	retainedLines := len(m.settledLines)
	retainedBytes := m.settledLinesBytes
	droppedLines := m.droppedSettledLines

	// Scroll direction state for dynamic triangle-wave traversal across entire scrollback
	scrollDirection := -1 // start by scrolling upward from bottom

	// Warmup
	for i := 0; i < 20; i++ {
		m, _ = m.Update(tea.MouseWheelMsg{Button: tea.MouseWheelUp})
		_ = m.View()
	}

	scrollUpdateDurs := make([]time.Duration, sampleCount)
	var streamUpdateDurs []time.Duration
	if streaming {
		streamUpdateDurs = make([]time.Duration, 0, sampleCount)
	}
	viewDurs := make([]time.Duration, sampleCount)
	pureScrollDurs := make([]time.Duration, sampleCount)
	var interleavedFrameDurs []time.Duration
	if streaming {
		interleavedFrameDurs = make([]time.Duration, 0, sampleCount)
	}

	seenHashes := make(map[string]struct{})
	seenOffsets := make(map[int]struct{})
	lastOffset := m.scrollOffset
	lastHash := ""
	movingSteps := 0
	contentChangedSteps := 0

	for i := 0; i < sampleCount; i++ {
		var streamDur time.Duration
		isStreamInterleaved := false

		// Interleave active token stream every 2 steps if streaming is enabled
		if streaming && (i%2 == 0) {
			isStreamInterleaved = true
			streamMsg := ChatStreamEventMsg{
				SessionID:  m.SessionID,
				Generation: m.Generation,
				Event: daemon.StreamEvent{
					Type: daemon.EventText,
					Text: fmt.Sprintf(" tok_%d", i),
				},
			}
			tStream0 := time.Now()
			m, _ = m.Update(streamMsg)
			streamDur = time.Since(tStream0)
			streamUpdateDurs = append(streamUpdateDurs, streamDur)
		}

		// Dynamically generate action to guarantee continuous motion across full buffer
		var act tea.Msg
		maxScroll := max(0, len(m.settledLines)-m.Viewport.Height())
		if scrollDirection < 0 {
			if m.scrollOffset <= 0 {
				scrollDirection = 1
				act = tea.MouseWheelMsg{Button: tea.MouseWheelDown}
			} else if i%25 == 0 {
				act = tea.KeyPressMsg{Code: tea.KeyPgUp}
			} else {
				act = tea.MouseWheelMsg{Button: tea.MouseWheelUp}
			}
		} else {
			if m.scrollOffset >= maxScroll {
				scrollDirection = -1
				act = tea.MouseWheelMsg{Button: tea.MouseWheelUp}
			} else if i%25 == 0 {
				act = tea.KeyPressMsg{Code: tea.KeyPgDown}
			} else {
				act = tea.MouseWheelMsg{Button: tea.MouseWheelDown}
			}
		}

		t0 := time.Now()
		var cmd tea.Cmd
		m, cmd = m.Update(act)
		_ = cmd
		uDur := time.Since(t0)

		t1 := time.Now()
		vStr := m.View()
		vDur := time.Since(t1)

		scrollUpdateDurs[i] = uDur
		viewDurs[i] = vDur
		pureScrollDurs[i] = uDur + vDur

		if isStreamInterleaved {
			interleavedFrameDurs = append(interleavedFrameDurs, streamDur+uDur+vDur)
		}

		h := hashString(vStr)
		if m.scrollOffset != lastOffset {
			movingSteps++
			lastOffset = m.scrollOffset
		}
		if h != lastHash {
			contentChangedSteps++
			lastHash = h
		}
		seenHashes[h] = struct{}{}
		seenOffsets[m.scrollOffset] = struct{}{}
	}

	uDist := calcDistribution(scrollUpdateDurs)
	vDist := calcDistribution(viewDurs)
	pureDist := calcDistribution(pureScrollDurs)

	var streamDist, interleavedDist LatencyDistribution
	primaryGateDist := pureDist

	if streaming && len(streamUpdateDurs) > 0 {
		streamDist = calcDistribution(streamUpdateDurs)
		interleavedDist = calcDistribution(interleavedFrameDurs)
		// For streaming scenarios, the primary gate assesses the interleaved frame budget (stream+scroll+view)
		primaryGateDist = interleavedDist
	}

	// Measure real allocations and bytes per op on a representative scroll op
	allocSampleModel := m
	var memBefore, memAfter runtime.MemStats
	benchRuns := 100
	runtime.GC()
	runtime.ReadMemStats(&memBefore)
	allocs := testing.AllocsPerRun(benchRuns, func() {
		testM, _ := allocSampleModel.Update(tea.KeyPressMsg{Code: tea.KeyPgUp})
		_ = testM.View()
	})
	runtime.ReadMemStats(&memAfter)
	bytesPerOp := uint64(0)
	if memAfter.TotalAlloc > memBefore.TotalAlloc {
		bytesPerOp = (memAfter.TotalAlloc - memBefore.TotalAlloc) / uint64(benchRuns)
	}

	name := fmt.Sprintf("%dx%d_%s", width, height, map[bool]string{false: "settled", true: "streaming"}[streaming])
	budget8ms := 8333333 * time.Nanosecond
	passes := primaryGateDist.P95 <= budget8ms && primaryGateDist.P99 <= budget8ms

	reason := "PASS: p95 & p99 within 8.333ms budget"
	if !passes {
		if primaryGateDist.P95 > budget8ms {
			reason = fmt.Sprintf("FAIL: p95 (%v) exceeds 8.333ms", primaryGateDist.P95)
		} else {
			reason = fmt.Sprintf("FAIL: p99 (%v) exceeds 8.333ms (tail jitter)", primaryGateDist.P99)
		}
	}

	movingFrameRatio := float64(movingSteps) / float64(sampleCount)
	contentChangeRatio := float64(contentChangedSteps) / float64(sampleCount)
	uniqueOffsets := len(seenOffsets)
	// Rigorous non-vacuous requirement:
	// 1. At least 90% of steps must actively move the scroll offset.
	// 2. At least 90% of steps must produce rendered content different from the previous step.
	// 3. At least 100 distinct buffer offsets must be traversed (avoiding trivial tight oscillating loops).
	nonVacuous := movingFrameRatio >= 0.90 && contentChangeRatio >= 0.90 && uniqueOffsets >= 100

	return ScenarioResult{
		Name:                      name,
		Width:                     width,
		Height:                    height,
		Streaming:                 streaming,
		RetainedLines:             retainedLines,
		RetainedBytes:             retainedBytes,
		DroppedLines:              droppedLines,
		AppendedEntries:           appendedCount,
		UniqueViewHashes:          len(seenHashes),
		UniqueOffsetsVisited:      uniqueOffsets,
		TotalScrollSteps:          sampleCount,
		MovingSteps:               movingSteps,
		ContentChangedSteps:       contentChangedSteps,
		MovingFrameRatio:          movingFrameRatio,
		ContentChangeRatio:        contentChangeRatio,
		NonVacuous:                nonVacuous,
		ScrollUpdateLatencies:     uDist,
		StreamUpdateLatencies:     streamDist,
		ViewLatencies:             vDist,
		PureScrollLatencies:       pureDist,
		InterleavedFrameLatencies: interleavedDist,
		PrimaryGateLatencies:      primaryGateDist,
		Passes120HzGate:           passes,
		GateReason:                reason,
		AllocsPerOp:               uint64(allocs),
		BytesPerOp:                bytesPerOp,
	}
}

// osSinkRecordingWriter wraps a real OS file descriptor (e.g. os.Pipe) and records
// actual kernel write() syscall counts, latencies, and byte volume.
// NOTE: os.Pipe is an OS kernel pipe, NOT a physical terminal or PTY device.
// write_calls includes all writes (startup ANSI, frame updates, and cleanup sequences).
type osSinkRecordingWriter struct {
	mu             sync.Mutex
	sinkFile       *os.File
	sinkName       string
	isTerminal     bool
	totalBytes     int64
	writeCalls     int
	writeDurations []time.Duration
}

func (w *osSinkRecordingWriter) Write(p []byte) (n int, err error) {
	t0 := time.Now()
	n, err = w.sinkFile.Write(p)
	dur := time.Since(t0)

	w.mu.Lock()
	w.totalBytes += int64(n)
	w.writeCalls++
	w.writeDurations = append(w.writeDurations, dur)
	w.mu.Unlock()

	return n, err
}

type OutputSyscallResult struct {
	SinkName               string              `json:"sink_name"`
	IsTerminal             bool                `json:"is_terminal"`
	SinkFd                 int                 `json:"sink_fd"`
	EventsDispatched       int                 `json:"events_dispatched"`
	WriteCalls             int                 `json:"write_calls"`
	ElapsedDuration        string              `json:"elapsed_duration"`
	ElapsedSeconds         float64             `json:"elapsed_seconds"`
	DispatchRateHz         float64             `json:"dispatch_rate_hz"`
	WriteCallRateHz        float64             `json:"write_call_rate_hz"`
	TotalBytesEmitted      int64               `json:"total_bytes_emitted"`
	ThroughputKBps         float64             `json:"throughput_kb_per_sec"`
	ThroughputMBps         float64             `json:"throughput_mb_per_sec"`
	PerWriteSyscallLatency LatencyDistribution `json:"per_write_syscall_latency"`
}

func runBubbleTeaProgramEmissionTest() (OutputSyscallResult, error) {
	session := &daemon.Session{ID: "perf-prog-sess", Workspace: "/workspace/prog"}
	m := NewChatModel(session, nil)
	m.SetSize(120, 40)
	buildRealisticHistory(&m)

	var sinkFile *os.File
	var sinkName string
	var cleanup func()

	// Check if stdout is an actual terminal / PTY and opt-in flag is enabled
	if isatty.IsTerminal(os.Stdout.Fd()) && os.Getenv("ALBEDO_TEST_USE_STDOUT_PTY") == "1" {
		sinkFile = os.Stdout
		sinkName = fmt.Sprintf("terminal PTY (stdout fd %d)", os.Stdout.Fd())
		cleanup = func() {}
	} else {
		// Use real OS kernel pipe with active draining reader.
		// NOTE: os.Pipe is an OS kernel pipe, NOT a terminal PTY.
		pr, pw, err := os.Pipe()
		if err != nil {
			return OutputSyscallResult{}, fmt.Errorf("failed to create os.Pipe: %w", err)
		}
		sinkFile = pw
		sinkName = fmt.Sprintf("os.Pipe (kernel syscall stream fd %d, not a PTY)", pw.Fd())
		doneDrain := make(chan struct{})
		go func() {
			defer close(doneDrain)
			buf := make([]byte, 64*1024)
			for {
				_, err := pr.Read(buf)
				if err != nil {
					return
				}
			}
		}()
		cleanup = func() {
			_ = pw.Close()
			_ = pr.Close()
			<-doneDrain
		}
	}
	defer cleanup()

	isTerm := isatty.IsTerminal(sinkFile.Fd())
	writer := &osSinkRecordingWriter{
		sinkFile:   sinkFile,
		sinkName:   sinkName,
		isTerminal: isTerm,
	}

	totalEvents := 120
	wrapper := bubbleTeaBenchmarkWrapper{
		chat:       m,
		eventsLeft: totalEvents,
	}

	inBuf := &bytes.Buffer{}
	p := tea.NewProgram(
		wrapper,
		tea.WithInput(inBuf),
		tea.WithOutput(writer),
		// A pipe reports a 0x0 window, where the renderer draws nothing; use
		// the chat's size so emission stays measurable.
		tea.WithWindowSize(120, 40),
		tea.WithFPS(120),
		tea.WithoutSignals(),
		tea.WithoutSignalHandler(),
		tea.WithoutCatchPanics(),
	)

	errCh := make(chan error, 1)
	go func() {
		_, err := p.Run()
		errCh <- err
	}()

	ticker := time.NewTicker(time.Second / 120)
	defer ticker.Stop()

	t0 := time.Now()
	for i := 0; i < totalEvents; i++ {
		<-ticker.C
		if i%2 == 0 {
			p.Send(tea.KeyPressMsg{Code: tea.KeyPgUp})
		} else {
			p.Send(tea.KeyPressMsg{Code: tea.KeyPgDown})
		}
	}

	select {
	case err := <-errCh:
		if err != nil {
			return OutputSyscallResult{}, err
		}
	case <-time.After(4 * time.Second):
		p.Kill()
		return OutputSyscallResult{}, fmt.Errorf("bubble tea program run timed out")
	}
	elapsed := time.Since(t0)

	writer.mu.Lock()
	calls := writer.writeCalls
	totalBytes := writer.totalBytes
	durs := make([]time.Duration, len(writer.writeDurations))
	copy(durs, writer.writeDurations)
	writer.mu.Unlock()

	sec := elapsed.Seconds()
	dispatchRate := float64(totalEvents) / sec
	writeCallRate := float64(calls) / sec
	kbps := float64(totalBytes) / sec / 1024.0
	mbps := float64(totalBytes) / sec / (1024.0 * 1024.0)

	return OutputSyscallResult{
		SinkName:               sinkName,
		IsTerminal:             isTerm,
		SinkFd:                 int(sinkFile.Fd()),
		EventsDispatched:       totalEvents,
		WriteCalls:             calls,
		ElapsedDuration:        elapsed.String(),
		ElapsedSeconds:         sec,
		DispatchRateHz:         dispatchRate,
		WriteCallRateHz:        writeCallRate,
		TotalBytesEmitted:      totalBytes,
		ThroughputKBps:         kbps,
		ThroughputMBps:         mbps,
		PerWriteSyscallLatency: calcDistribution(durs),
	}, nil
}

type AcceptanceReport struct {
	Timestamp            string              `json:"timestamp"`
	TotalElapsed         string              `json:"total_elapsed"`
	StrictGateMode       bool                `json:"strict_gate_mode"`
	MemBefore            MemorySnapshot      `json:"mem_before"`
	MemAfter             MemorySnapshot      `json:"mem_after"`
	NumGC                int64               `json:"num_gc"`
	LastGCPause          string              `json:"last_gc_pause"`
	OutputSyscallProfile OutputSyscallResult `json:"output_syscall_profile"`
	Results              []ScenarioResult    `json:"results"`
}

func TestScrollPerf_AcceptanceGate(t *testing.T) {
	// Skip unless explicitly opt-in to keep standard unit and race test suites fast
	if os.Getenv("ALBEDO_SCROLL_PERF") != "1" && os.Getenv("ALBEDO_PERF_STRICT") != "1" {
		t.Skip("skipping scroll perf acceptance gate; set ALBEDO_SCROLL_PERF=1 or ALBEDO_PERF_STRICT=1 to run")
	}

	memBefore := readMem()
	t0 := time.Now()

	scenarios := []struct {
		w, h      int
		streaming bool
	}{
		{120, 40, false},
		{120, 40, true},
		{180, 60, false},
		{180, 60, true},
	}

	strictGate := os.Getenv("ALBEDO_PERF_STRICT") == "1"
	results := make([]ScenarioResult, len(scenarios))

	for i, sc := range scenarios {
		res := runScrollScenario(sc.w, sc.h, sc.streaming, 500)
		results[i] = res

		if !res.NonVacuous {
			msg := fmt.Sprintf("Scenario %s failed non-vacuous check: moving frames=%.1f%%, content changed=%.1f%%, unique offsets=%d",
				res.Name, res.MovingFrameRatio*100, res.ContentChangeRatio*100, res.UniqueOffsetsVisited)
			if strictGate {
				t.Errorf("%s", msg)
			} else {
				t.Logf("WARN: %s", msg)
			}
		}

		if res.RetainedLines > MaxSettledLines {
			t.Errorf("Scenario %s retained lines (%d) exceeded MaxSettledLines (%d)", res.Name, res.RetainedLines, MaxSettledLines)
		}

		if strictGate && !res.Passes120HzGate {
			t.Errorf("Scenario %s failed 120Hz acceptance gate: %s", res.Name, res.GateReason)
		}

		t.Logf("=== SCENARIO: %s ===", res.Name)
		t.Logf("  Retained: %d lines (%d bytes), Dropped: %d lines", res.RetainedLines, res.RetainedBytes, res.DroppedLines)
		t.Logf("  Motion: %d moving frames (%.1f%%), %d content changed (%.1f%%), %d unique offsets, %d unique digests",
			res.MovingSteps, res.MovingFrameRatio*100, res.ContentChangedSteps, res.ContentChangeRatio*100, res.UniqueOffsetsVisited, res.UniqueViewHashes)
		t.Logf("  Scroll Update: p50=%v, p95=%v, p99=%v", res.ScrollUpdateLatencies.Median, res.ScrollUpdateLatencies.P95, res.ScrollUpdateLatencies.P99)
		if res.Streaming {
			t.Logf("  Stream Update: p50=%v, p95=%v, p99=%v", res.StreamUpdateLatencies.Median, res.StreamUpdateLatencies.P95, res.StreamUpdateLatencies.P99)
		}
		t.Logf("  View Latency:  p50=%v, p95=%v, p99=%v", res.ViewLatencies.Median, res.ViewLatencies.P95, res.ViewLatencies.P99)
		t.Logf("  Primary Gate Latency (p50=%v, p95=%v, p99=%v, max=%v): %.1f%% under 120Hz",
			res.PrimaryGateLatencies.Median, res.PrimaryGateLatencies.P95, res.PrimaryGateLatencies.P99, res.PrimaryGateLatencies.Max,
			res.PrimaryGateLatencies.PctUnder120)
		t.Logf("  Allocs/op: %d, Bytes/op: %d", res.AllocsPerOp, res.BytesPerOp)
		t.Logf("  Verdict: %s", res.GateReason)
	}

	// Real Bubble Tea output write syscall measurement
	syscallResult, err := runBubbleTeaProgramEmissionTest()
	if err != nil {
		t.Fatalf("Bubble Tea program output syscall run failed: %v", err)
	}
	t.Logf("=== BUBBLE TEA OUTPUT SYSCALL PROFILE ===")
	t.Logf("  Sink: %s (isTerminal=%v, fd=%d; note: os.Pipe != PTY)", syscallResult.SinkName, syscallResult.IsTerminal, syscallResult.SinkFd)
	t.Logf("  Dispatched: %d events in %.2fs (%.1f Hz input rate)", syscallResult.EventsDispatched, syscallResult.ElapsedSeconds, syscallResult.DispatchRateHz)
	t.Logf("  Raw Write Syscalls: %d calls (%.1f calls/sec; includes setup/diff/cleanup writes)", syscallResult.WriteCalls, syscallResult.WriteCallRateHz)
	t.Logf("  Bytes Written: %d bytes (%.2f KB/s, %.2f MB/s)", syscallResult.TotalBytesEmitted, syscallResult.ThroughputKBps, syscallResult.ThroughputMBps)
	t.Logf("  Per-Write Syscall Latency (file.Write): p50=%v, p95=%v, p99=%v, max=%v",
		syscallResult.PerWriteSyscallLatency.Median, syscallResult.PerWriteSyscallLatency.P95,
		syscallResult.PerWriteSyscallLatency.P99, syscallResult.PerWriteSyscallLatency.Max)

	memAfter := readMem()
	totalElapsed := time.Since(t0)

	var gcStats debug.GCStats
	debug.ReadGCStats(&gcStats)

	report := AcceptanceReport{
		Timestamp:            time.Now().UTC().Format(time.RFC3339),
		TotalElapsed:         totalElapsed.String(),
		StrictGateMode:       strictGate,
		MemBefore:            memBefore,
		MemAfter:             memAfter,
		NumGC:                gcStats.NumGC,
		OutputSyscallProfile: syscallResult,
		Results:              results,
	}
	if len(gcStats.Pause) > 0 {
		report.LastGCPause = gcStats.Pause[0].String()
	}

	data, err := json.MarshalIndent(report, "", "  ")
	if err == nil {
		_ = os.WriteFile("/tmp/albedo-scroll-perf-data.json", data, 0644)
	}
}

// bubbleTeaBenchmarkWrapper wraps ChatModel as a tea.Model for program-level testing.
type bubbleTeaBenchmarkWrapper struct {
	chat       ChatModel
	eventsLeft int
}

func (w bubbleTeaBenchmarkWrapper) Init() tea.Cmd {
	return nil
}

func (w bubbleTeaBenchmarkWrapper) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if _, ok := msg.(tea.KeyPressMsg); ok {
		w.eventsLeft--
		if w.eventsLeft <= 0 {
			return w, tea.Quit
		}
	}
	newChat, cmd := w.chat.Update(msg)
	w.chat = newChat
	return w, cmd
}

func (w bubbleTeaBenchmarkWrapper) View() tea.View {
	return tea.NewView(w.chat.View())
}

// Standard Go Benchmarks

func BenchmarkScroll_UpdateView_120x40_Settled(b *testing.B) {
	session := &daemon.Session{ID: "bench-sess", Workspace: "/workspace"}
	m := NewChatModel(session, nil)
	m.SetSize(120, 40)
	buildRealisticHistory(&m)

	upMsg := tea.KeyPressMsg{Code: tea.KeyPgUp}
	downMsg := tea.KeyPressMsg{Code: tea.KeyPgDown}

	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		if i%2 == 0 {
			m, _ = m.Update(upMsg)
		} else {
			m, _ = m.Update(downMsg)
		}
		_ = m.View()
	}
}

func BenchmarkScroll_UpdateView_180x60_Settled(b *testing.B) {
	session := &daemon.Session{ID: "bench-sess", Workspace: "/workspace"}
	m := NewChatModel(session, nil)
	m.SetSize(180, 60)
	buildRealisticHistory(&m)

	upMsg := tea.KeyPressMsg{Code: tea.KeyPgUp}
	downMsg := tea.KeyPressMsg{Code: tea.KeyPgDown}

	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		if i%2 == 0 {
			m, _ = m.Update(upMsg)
		} else {
			m, _ = m.Update(downMsg)
		}
		_ = m.View()
	}
}

func BenchmarkScroll_UpdateView_120x40_Streaming(b *testing.B) {
	session := &daemon.Session{ID: "bench-sess", Workspace: "/workspace"}
	m := NewChatModel(session, nil)
	m.SetSize(120, 40)
	buildRealisticHistory(&m)

	upMsg := tea.KeyPressMsg{Code: tea.KeyPgUp}
	downMsg := tea.KeyPressMsg{Code: tea.KeyPgDown}

	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		if i%2 == 0 {
			m, _ = m.Update(ChatStreamEventMsg{
				SessionID:  m.SessionID,
				Generation: m.Generation,
				Event:      daemon.StreamEvent{Type: daemon.EventText, Text: " tok"},
			})
		}
		if i%2 == 0 {
			m, _ = m.Update(upMsg)
		} else {
			m, _ = m.Update(downMsg)
		}
		_ = m.View()
	}
}

func BenchmarkScroll_UpdateView_180x60_Streaming(b *testing.B) {
	session := &daemon.Session{ID: "bench-sess", Workspace: "/workspace"}
	m := NewChatModel(session, nil)
	m.SetSize(180, 60)
	buildRealisticHistory(&m)

	upMsg := tea.KeyPressMsg{Code: tea.KeyPgUp}
	downMsg := tea.KeyPressMsg{Code: tea.KeyPgDown}

	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		if i%2 == 0 {
			m, _ = m.Update(ChatStreamEventMsg{
				SessionID:  m.SessionID,
				Generation: m.Generation,
				Event:      daemon.StreamEvent{Type: daemon.EventText, Text: " tok"},
			})
		}
		if i%2 == 0 {
			m, _ = m.Update(upMsg)
		} else {
			m, _ = m.Update(downMsg)
		}
		_ = m.View()
	}
}
