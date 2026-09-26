package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"runtime/pprof"
	"strconv"
	"strings"
	"testing"
	"time"
)

const profileDir = "/tmp/albedo-memory-profile"

type ProcessOSMemory struct {
	PID              int     `json:"pid"`
	RSSBytes         uint64  `json:"rss_bytes"`
	RSSFormatted     string  `json:"rss_formatted"`
	MaxRSSBytes      uint64  `json:"max_rss_bytes"`
	VMMapFootprintMB float64 `json:"vmmap_footprint_mb"`
	VMMapRawSummary  string  `json:"vmmap_raw_summary,omitempty"`
}

func readOSMemory() ProcessOSMemory {
	pid := os.Getpid()
	var rusage runtime.MemStats
	runtime.ReadMemStats(&rusage)

	mem := ProcessOSMemory{
		PID: pid,
	}

	// Read RSS via ps
	out, err := exec.Command("ps", "-o", "rss=", "-p", strconv.Itoa(pid)).Output()
	if err == nil {
		rssKb, err := strconv.ParseUint(strings.TrimSpace(string(out)), 10, 64)
		if err == nil {
			mem.RSSBytes = rssKb * 1024
			mem.RSSFormatted = fmt.Sprintf("%.2f MB", float64(mem.RSSBytes)/(1024*1024))
		}
	}

	// Read macOS vmmap summary if available
	vmOut, err := exec.Command("vmmap", "-summary", strconv.Itoa(pid)).Output()
	if err == nil {
		lines := strings.Split(string(vmOut), "\n")
		for _, line := range lines {
			if strings.HasPrefix(line, "Physical footprint:") {
				parts := strings.Fields(line)
				if len(parts) >= 3 {
					valStr := parts[2]
					if strings.HasSuffix(valStr, "K") {
						if f, err := strconv.ParseFloat(strings.TrimSuffix(valStr, "K"), 64); err == nil {
							mem.VMMapFootprintMB = f / 1024.0
						}
					} else if strings.HasSuffix(valStr, "M") {
						if f, err := strconv.ParseFloat(strings.TrimSuffix(valStr, "M"), 64); err == nil {
							mem.VMMapFootprintMB = f
						}
					} else if strings.HasSuffix(valStr, "G") {
						if f, err := strconv.ParseFloat(strings.TrimSuffix(valStr, "G"), 64); err == nil {
							mem.VMMapFootprintMB = f * 1024.0
						}
					}
				}
				break
			}
		}
	}

	return mem
}

type PhaseMetrics struct {
	PhaseName            string          `json:"phase_name"`
	PhaseDescription     string          `json:"phase_description"`
	Timestamp            string          `json:"timestamp"`
	OSMemory             ProcessOSMemory `json:"os_memory"`
	HeapAllocBytes       uint64          `json:"heap_alloc_bytes"`
	HeapInuseBytes       uint64          `json:"heap_inuse_bytes"`
	HeapIdleBytes        uint64          `json:"heap_idle_bytes"`
	HeapReleasedBytes    uint64          `json:"heap_released_bytes"`
	StackInuseBytes      uint64          `json:"stack_inuse_bytes"`
	MSpanInuseBytes      uint64          `json:"mspan_inuse_bytes"`
	MCacheInuseBytes     uint64          `json:"mcache_inuse_bytes"`
	OtherSysBytes        uint64          `json:"other_sys_bytes"`
	SysBytes             uint64          `json:"sys_bytes"`
	NumGC                uint32          `json:"num_gc"`
	HeapProfilePath      string          `json:"heap_profile_path"`
	ModelRetainedEntries int             `json:"model_retained_entries,omitempty"`
	ModelRetainedBytes   int64           `json:"model_retained_bytes,omitempty"`
	ModelDroppedLines    int             `json:"model_dropped_lines,omitempty"`
}

func capturePhaseMetrics(phaseName, description, pprofFilename string) (PhaseMetrics, error) {
	_ = os.MkdirAll(profileDir, 0755)
	pprofPath := filepath.Join(profileDir, pprofFilename)

	// CRITICAL: Capture runtime.MemStats and OS memory BEFORE writing the heap profile.
	// Writing a gzip-compressed heap profile allocates runtime buffers and formatting
	// memory which would contaminate HeapAlloc and HeapInuse if measured after.
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	osMem := readOSMemory()

	// Write heap profile snapshot for call-site attribution
	f, err := os.Create(pprofPath)
	if err != nil {
		return PhaseMetrics{}, fmt.Errorf("failed to create pprof file: %w", err)
	}
	defer f.Close()

	if err := pprof.WriteHeapProfile(f); err != nil {
		return PhaseMetrics{}, fmt.Errorf("failed to write heap profile: %w", err)
	}

	return PhaseMetrics{
		PhaseName:         phaseName,
		PhaseDescription:  description,
		Timestamp:         time.Now().UTC().Format(time.RFC3339),
		OSMemory:          osMem,
		HeapAllocBytes:    m.HeapAlloc,
		HeapInuseBytes:    m.HeapInuse,
		HeapIdleBytes:     m.HeapIdle,
		HeapReleasedBytes: m.HeapReleased,
		StackInuseBytes:   m.StackInuse,
		MSpanInuseBytes:   m.MSpanInuse,
		MCacheInuseBytes:  m.MCacheInuse,
		OtherSysBytes:     m.OtherSys,
		SysBytes:          m.Sys,
		NumGC:             m.NumGC,
		HeapProfilePath:   pprofPath,
	}, nil
}

// TestMemoryProfile_FreshPicker captures Phase 1: Fresh App Picker Idle.
func TestMemoryProfile_FreshPicker(t *testing.T) {
	if os.Getenv("ALBEDO_MEM_PROFILE") != "1" {
		t.Skip("skipping memory profiling; set ALBEDO_MEM_PROFILE=1 to run")
	}

	// Fresh AppModel with no active session => Session Picker state
	app := NewAppModel(nil, config.Profiles{}, nil, "/workspace/fresh", false)
	newApp, _ := app.Update(tea.WindowSizeMsg{Width: 120, Height: 40})
	app = newApp.(AppModel)
	_ = app.View()

	metrics, err := capturePhaseMetrics(
		"fresh_picker_idle",
		"Fresh AppModel in Session Picker state before loading any chat session",
		"fresh_picker_heap.pb.gz",
	)
	if err != nil {
		t.Fatalf("failed to capture fresh picker metrics: %v", err)
	}

	// Retain app alive strictly AFTER capture
	runtime.KeepAlive(&app)

	data, _ := json.MarshalIndent(metrics, "", "  ")
	_ = os.WriteFile(filepath.Join(profileDir, "fresh_picker.json"), data, 0644)
	t.Logf("=== PHASE 1: FRESH PICKER IDLE ===")
	t.Logf("  RSS: %s (vmmap footprint: %.1f MB)", metrics.OSMemory.RSSFormatted, metrics.OSMemory.VMMapFootprintMB)
	t.Logf("  HeapAlloc: %d B (%.2f MB), HeapInuse: %d B (%.2f MB), Sys: %d B (%.2f MB)",
		metrics.HeapAllocBytes, float64(metrics.HeapAllocBytes)/(1024*1024),
		metrics.HeapInuseBytes, float64(metrics.HeapInuseBytes)/(1024*1024),
		metrics.SysBytes, float64(metrics.SysBytes)/(1024*1024))
}

// TestMemoryProfile_PostStreamStress captures Phase 2 (Natural Idle) and Phase 3 (Diagnostic Forced-GC Idle)
// under an uninterrupted 300KB+ SSE stress transcript.
func TestMemoryProfile_PostStreamStress(t *testing.T) {
	if os.Getenv("ALBEDO_MEM_PROFILE") != "1" {
		t.Skip("skipping memory profiling; set ALBEDO_MEM_PROFILE=1 to run")
	}

	session := &daemon.Session{ID: "sess-mem-stress", Workspace: "/workspace/stress"}
	app := NewAppModel(nil, config.Profiles{}, session, "/workspace/stress", false)
	newApp, _ := app.Update(tea.WindowSizeMsg{Width: 120, Height: 40})
	app = newApp.(AppModel)

	// Stream 1,200 chunks of ~270 bytes each = ~325 KB (matching canonical SSE stress flow)
	chunkTemplate := "assistant token chunk with code snippet `let mut ring = RingBuffer::new(4096);` and multiline buffer text for stress testing memory retention, history truncation bounds, and viewport rendering performance invariants across large scrollback buffers\n"
	totalChunks := 1200
	totalStreamedBytes := 0

	var fullStreamBuilder strings.Builder
	for i := 0; i < totalChunks; i++ {
		chunkText := fmt.Sprintf("[%04d] %s", i, chunkTemplate)
		totalStreamedBytes += len(chunkText)
		fullStreamBuilder.WriteString(chunkText)

		msg := ChatStreamEventMsg{
			SessionID:  app.Chat.SessionID,
			Generation: app.Chat.Generation,
			Event: daemon.StreamEvent{
				Type: daemon.EventText,
				Text: chunkText,
			},
		}
		newApp, _ := app.Update(msg)
		app = newApp.(AppModel)
	}

	// Settle the stream with canonical EventMessage containing the full original stream content
	canonicalFullText := fullStreamBuilder.String()
	settleMsg := ChatStreamEventMsg{
		SessionID:  app.Chat.SessionID,
		Generation: app.Chat.Generation,
		Event: daemon.StreamEvent{
			Type: daemon.EventMessage,
			Text: canonicalFullText,
		},
	}
	newApp, _ = app.Update(settleMsg)
	app = newApp.(AppModel)

	// Explicitly release fixture memory references before taking snapshots
	canonicalFullText = ""
	fullStreamBuilder.Reset()

	// Populate rendered viewport cache
	_ = app.View()

	// Verify transcript invariants
	if app.Chat.activeKind != StreamKindNone {
		t.Errorf("expected activeKind to be None after settle, got %v", app.Chat.activeKind)
	}
	if len(app.Chat.pendingUsers) != 0 {
		t.Errorf("expected pendingUsers to be empty, got %d", len(app.Chat.pendingUsers))
	}

	// Let runtime settle naturally
	time.Sleep(50 * time.Millisecond)

	// Phase 2: Natural Post-Stream Idle (NO forced GC; represents real runtime idle with floating garbage)
	naturalMetrics, err := capturePhaseMetrics(
		"post_stream_natural_idle",
		"Post-stream settled state under natural Go GC (canonical 325KB stream settled, rendered cache populated, pending zero)",
		"post_stream_natural_heap.pb.gz",
	)
	if err != nil {
		t.Fatalf("failed to capture natural post-stream metrics: %v", err)
	}
	naturalMetrics.ModelRetainedEntries = app.Chat.History.Len()
	naturalMetrics.ModelRetainedBytes = app.Chat.History.TotalBytes()
	naturalMetrics.ModelDroppedLines = app.Chat.droppedSettledLines

	// Phase 3: Diagnostic Forced-GC + Explicit FreeOSMemory Idle
	// Explicitly forces full GC sweep and OS madvise return to distinguish live objects from allocator spans.
	runtime.GC()
	debug.FreeOSMemory()
	time.Sleep(20 * time.Millisecond)

	diagnosticMetrics, err := capturePhaseMetrics(
		"post_stream_diagnostic_gc_idle",
		"Post-stream settled state after diagnostic runtime.GC() + debug.FreeOSMemory() to isolate true live retained objects",
		"post_stream_diagnostic_gc_heap.pb.gz",
	)
	if err != nil {
		t.Fatalf("failed to capture diagnostic GC metrics: %v", err)
	}
	diagnosticMetrics.ModelRetainedEntries = app.Chat.History.Len()
	diagnosticMetrics.ModelRetainedBytes = app.Chat.History.TotalBytes()
	diagnosticMetrics.ModelDroppedLines = app.Chat.droppedSettledLines

	// Retain app alive strictly AFTER all captures
	runtime.KeepAlive(&app)

	dataNat, _ := json.MarshalIndent(naturalMetrics, "", "  ")
	_ = os.WriteFile(filepath.Join(profileDir, "post_stream_natural.json"), dataNat, 0644)

	dataDiag, _ := json.MarshalIndent(diagnosticMetrics, "", "  ")
	_ = os.WriteFile(filepath.Join(profileDir, "post_stream_diagnostic.json"), dataDiag, 0644)

	t.Logf("=== PHASE 2: POST-STREAM NATURAL IDLE ===")
	t.Logf("  Streamed: %d bytes across %d chunks", totalStreamedBytes, totalChunks)
	t.Logf("  Model: %d entries (%d B), %d dropped lines", naturalMetrics.ModelRetainedEntries, naturalMetrics.ModelRetainedBytes, naturalMetrics.ModelDroppedLines)
	t.Logf("  RSS: %s (vmmap footprint: %.1f MB)", naturalMetrics.OSMemory.RSSFormatted, naturalMetrics.OSMemory.VMMapFootprintMB)
	t.Logf("  Allocated Heap (pre-GC): %d B (%.2f MB), HeapInuse: %d B (%.2f MB), Sys: %d B (%.2f MB)",
		naturalMetrics.HeapAllocBytes, float64(naturalMetrics.HeapAllocBytes)/(1024*1024),
		naturalMetrics.HeapInuseBytes, float64(naturalMetrics.HeapInuseBytes)/(1024*1024),
		naturalMetrics.SysBytes, float64(naturalMetrics.SysBytes)/(1024*1024))

	t.Logf("=== PHASE 3: POST-STREAM DIAGNOSTIC GC IDLE ===")
	t.Logf("  RSS: %s (vmmap footprint: %.1f MB)", diagnosticMetrics.OSMemory.RSSFormatted, diagnosticMetrics.OSMemory.VMMapFootprintMB)
	t.Logf("  Live Retained Heap (post-GC): %d B (%.2f MB), HeapInuse: %d B (%.2f MB), HeapReleased: %d B (%.2f MB)",
		diagnosticMetrics.HeapAllocBytes, float64(diagnosticMetrics.HeapAllocBytes)/(1024*1024),
		diagnosticMetrics.HeapInuseBytes, float64(diagnosticMetrics.HeapInuseBytes)/(1024*1024),
		diagnosticMetrics.HeapReleasedBytes, float64(diagnosticMetrics.HeapReleasedBytes)/(1024*1024))
}
