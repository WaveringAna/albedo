package daemon

import (
	"encoding/json"
	"errors"
	"unicode/utf8"

	"albedo/cli/internal/daemon/protocol"
)

// ToolActivity records display-only execution evidence, not model-facing tool output.
type ToolActivity struct {
	Kind   string `json:"kind"` // "read" | "search" | "list" | "run"
	Target string `json:"target"`
}

type FileChange struct {
	Path    string `json:"path"`
	Kind    string `json:"kind"` // "diff" | "unavailable"
	Diff    string `json:"diff,omitempty"`
	Reason  string `json:"reason,omitempty"`
	Added   int    `json:"added,omitempty"`
	Removed int    `json:"removed,omitempty"`
}

type ToolTrace struct {
	Activities []ToolActivity `json:"activities"`
	Changes    []FileChange   `json:"changes"`
	Truncated  bool           `json:"truncated,omitempty"`
}

// ParseToolTrace validates the display evidence encoded in a history or tool event.
func ParseToolTrace(data json.RawMessage) *ToolTrace {
	if len(data) == 0 {
		return nil
	}

	var trace ToolTrace
	if err := json.Unmarshal(data, &trace); err != nil {
		return nil
	}

	if len(trace.Activities) > 64 || len(trace.Changes) > 16 {
		return nil
	}

	for _, act := range trace.Activities {
		switch act.Kind {
		case "read", "search", "list", "run":
		default:
			return nil
		}
		// Python bounds these strings by Unicode characters, not UTF-8 bytes.
		if utf8.RuneCountInString(act.Target) > 1000 {
			return nil
		}
	}

	for _, ch := range trace.Changes {
		if utf8.RuneCountInString(ch.Path) > 1000 {
			return nil
		}
		switch ch.Kind {
		case "unavailable":
			if utf8.RuneCountInString(ch.Reason) > 1000 {
				return nil
			}
		case "diff":
			if utf8.RuneCountInString(ch.Diff) > 16000 || ch.Added < 0 || ch.Removed < 0 {
				return nil
			}
		default:
			return nil
		}
	}

	return &trace
}

// ToolCodePreview contains the latest bounded window of decoded source code.
type ToolCodePreview struct {
	Text   string `json:"text"`
	Offset int    `json:"offset"`
}

type ToolProgress struct {
	Code       *ToolCodePreview `json:"code,omitempty"`
	ToolCallID string           `json:"tool_call_id,omitempty"`
	CallID     string           `json:"call_id"`
	Name       string           `json:"name"`
	Phase      string           `json:"phase"` // "generating" | "running"
}

const maxActiveToolProgress = 32

type EventType string

const (
	EventReset          EventType = "reset"
	EventRetry          EventType = "retry"
	EventText           EventType = "text"
	EventError          EventType = "error"
	EventInterrupted    EventType = "interrupted"
	EventMessage        EventType = "message"
	EventUser           EventType = "user"
	EventTurnMembership EventType = "turn_membership"
	EventTurnCompleted  EventType = "turn_completed"
	EventThinking       EventType = "thinking"
	EventNote           EventType = "note"
	EventCompacted      EventType = "compacted"
	EventToolProgress   EventType = "tool_progress"
	EventTool           EventType = "tool"
	EventUsage          EventType = "usage"
	EventInvalidate     EventType = "invalidate"
	// EventCommitted says transcript rows up to Seq now cover what was shown.
	EventCommitted EventType = "committed"
)

type Usage struct {
	Model              string   `json:"model,omitempty"`
	RecordedAt         *int64   `json:"recordedAt,omitempty"`
	PromptTokens       *int     `json:"promptTokens,omitempty"`
	CachedPromptTokens *int     `json:"cachedPromptTokens,omitempty"`
	CacheWriteTokens   *int     `json:"cacheWriteTokens,omitempty"`
	CompletionTokens   *int     `json:"completionTokens,omitempty"`
	TotalTokens        *int     `json:"totalTokens,omitempty"`
	ElapsedMs          *float64 `json:"elapsedMs,omitempty"`
	TokensPerSecond    *float64 `json:"tokensPerSecond,omitempty"`
	// CacheFade is how CachedPromptTokens fades once the session goes quiet,
	// in time order.
	CacheFade []CacheStep `json:"cacheFade,omitempty"`
}

// CacheStep says that from At (unix ms) on, a request would read Cached
// tokens from the provider's cache; nil when that is no longer known.
type CacheStep struct {
	Cached *int  `json:"cached,omitempty"`
	At     int64 `json:"at"`
}

type StreamEvent struct {
	EntryID         string
	Position        int64
	TurnType        string
	Speaker         string
	MailKind        string
	SenderSessionID string
	Invalidation    *ResourceInvalidation
	Status          *AgentStatus
	Snapshot        *Session
	Receipt         *OperationReceipt
	OperationID     string
	Image           *ImageMetadata
	Usage           *Usage
	ToolTrace       *ToolTrace
	Timestamp       *int64
	ToolArgs        map[string]any
	Progress        *ToolProgress
	TurnID          string
	Type            EventType
	Text            string
	Source          string
	Summary         string
	Strategy        string
	ToolName        string
	ToolResult      string
	ProgressCallID  string
	SubmissionIDs   []string
	Evicted         int
	// ElapsedMs is how long a replayed thought took, when the daemon timed it.
	ElapsedMs       int64
	ElapsedObserved bool
	// Seq is the newest transcript row an EventCommitted covers.
	Seq int64
	// Before and More describe the history a reset or page carried: Before is
	// its first row (the cursor for the next older page), More whether one exists.
	Before int64
	More   bool
	// Replayed marks an event from the transcript snapshot that follows a
	// reset: history, which says nothing about what the session does now.
	Replayed bool
}

type ResourceInvalidation struct {
	Session, Settings, Catalog, Context, Extension bool
}

// decodeToolProgress validates the normalized progress object before delivery.
// A null value clears the current live progress.
func decodeToolProgress(raw json.RawMessage) (*ToolProgress, error) {
	if string(raw) == "null" {
		return nil, nil
	}
	if len(raw) > 8192 {
		return nil, errors.New("tool progress exceeds 8 KiB")
	}
	var wire protocol.ToolProgress
	if err := decodeRequired(raw, &wire, "call_id", "tool_call_id", "name", "phase", "intent"); err != nil {
		return nil, err
	}
	if wire.CallID == "" || wire.Name == "" || len(wire.Name) > 100 || (wire.Phase != "generating" && wire.Phase != "running") {
		return nil, fieldError("tool progress")
	}
	preview := value(wire.Preview)
	if preview.OffsetScalars < 0 || utf8.RuneCountInString(preview.Text) > 512 || len(preview.Text) > 2048 {
		return nil, fieldError("tool progress preview")
	}
	return progressValue(wire), nil
}
func progressValue(wire protocol.ToolProgress) *ToolProgress {
	progress := &ToolProgress{CallID: wire.CallID, ToolCallID: value(wire.ToolCallID), Name: wire.Name, Phase: wire.Phase}
	preview := value(wire.Preview)
	if preview.Text != "" || preview.OffsetScalars > 0 {
		progress.Code = &ToolCodePreview{Text: preview.Text, Offset: int(preview.OffsetScalars)}
	}
	return progress
}
func usageValue(wire protocol.Usage) *Usage {
	usage := &Usage{Model: value(wire.Model), PromptTokens: intPointer(wire.PromptTokens), CachedPromptTokens: intPointer(wire.CachedPromptTokens), CacheWriteTokens: intPointer(wire.CacheWriteTokens), CompletionTokens: intPointer(wire.CompletionTokens), TotalTokens: intPointer(wire.TotalTokens), ElapsedMs: wire.ElapsedMs, TokensPerSecond: wire.TokensPerSecond}
	if wire.ObservedAt != nil {
		usage.RecordedAt = timestampMilliseconds(*wire.ObservedAt)
	}
	for _, step := range wire.CacheFade {
		if at := timestampMilliseconds(step.At); at != nil {
			usage.CacheFade = append(usage.CacheFade, CacheStep{At: *at, Cached: intPointer(step.CachedTokens)})
		}
	}
	return usage
}
