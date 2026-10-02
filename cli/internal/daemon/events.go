package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"unicode"
)

// ToolActivity records display-only execution evidence, not model-facing tool output.
type ToolActivity struct {
	Kind   string `json:"kind"` // "read" | "search" | "list" | "run"
	Target string `json:"target"`
	Failed bool   `json:"failed,omitempty"`
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

// ParseToolTrace validates and extracts a ToolTrace from untyped data.
func ParseToolTrace(raw any) *ToolTrace {
	if raw == nil {
		return nil
	}

	data, err := json.Marshal(raw)
	if err != nil {
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
		if len(act.Target) > 1000 {
			return nil
		}
	}

	for _, ch := range trace.Changes {
		if len(ch.Path) > 1000 {
			return nil
		}
		switch ch.Kind {
		case "unavailable":
			if len(ch.Reason) > 1000 {
				return nil
			}
		case "diff":
			if len(ch.Diff) > 16000 || ch.Added < 0 || ch.Removed < 0 {
				return nil
			}
		default:
			return nil
		}
	}

	return &trace
}

// ToolIntent indicates inferred intent of a tool call.
type ToolIntent struct {
	Kind   string `json:"kind"` // "write" | "edit" | "read" | "run"
	Target string `json:"target"`
}

// ToolCodePreview is a window on a call's code: while it generates, the
// newest end; once it runs, the first line.
type ToolCodePreview struct {
	Text   string `json:"text"`
	Offset int    `json:"offset"`
}

type ToolProgress struct {
	Intent *ToolIntent      `json:"intent,omitempty"`
	Code   *ToolCodePreview `json:"code,omitempty"`
	CallID string           `json:"callId"`
	Name   string           `json:"name"`
	Phase  string           `json:"phase"` // "generating" | "running"
}

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
	Image         *ImageMetadata `json:"image,omitempty"`
	Usage         *Usage         `json:"usage,omitempty"`
	ToolTrace     *ToolTrace     `json:"trace,omitempty"`
	Timestamp     *int64         `json:"timestamp,omitempty"`
	ToolArgs      map[string]any `json:"args,omitempty"`
	Progress      *ToolProgress  `json:"progress,omitempty"`
	TurnID        string         `json:"turnId,omitempty"`
	Type          EventType      `json:"type"`
	Text          string         `json:"text,omitempty"`
	Role          string         `json:"role,omitempty"` // "assistant"
	Source        string         `json:"source,omitempty"`
	TriggeredAt   string         `json:"triggeredAt,omitempty"`
	ClientID      string         `json:"clientId,omitempty"`
	Summary       string         `json:"summary,omitempty"`
	Strategy      string         `json:"strategy,omitempty"`
	ToolName      string         `json:"name,omitempty"`
	ToolResult    string         `json:"result,omitempty"`
	SubmissionIDs []string       `json:"submissionIds,omitempty"`
	Evicted       int            `json:"evicted,omitempty"`
	// ElapsedMs is how long a replayed thought took, when the daemon timed it.
	ElapsedMs int64 `json:"elapsedMs,omitempty"`
	// Seq is the newest transcript row an EventCommitted covers.
	Seq int64 `json:"seq,omitempty"`
	// Before and More describe the history a reset or page carried: Before is
	// its first row (the cursor for the next older page), More whether one exists.
	Before int64 `json:"before,omitempty"`
	More   bool  `json:"more,omitempty"`
	// Replayed marks an event from the transcript snapshot that follows a
	// reset: history, which says nothing about what the session does now.
	Replayed bool `json:"-"`
}

func sanitizeControlRunes(s string) string {
	var sb strings.Builder
	for _, r := range s {
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) {
			sb.WriteRune(' ')
		} else {
			sb.WriteRune(r)
		}
	}
	return sb.String()
}

// validateToolProgress distinguishes a display reset from malformed known fields.
func validateToolProgress(raw json.RawMessage) error {
	if string(raw) == "null" {
		return nil
	}
	var progress struct {
		CallID *string `json:"callId"`
		Name   *string `json:"name"`
		Phase  *string `json:"phase"`
		Intent *struct {
			Kind   *string `json:"kind"`
			Target *string `json:"target"`
		} `json:"intent"`
		Code *struct {
			Text   *string `json:"text"`
			Offset *int    `json:"offset"`
		} `json:"code"`
	}
	if err := json.Unmarshal(raw, &progress); err != nil {
		return fmt.Errorf("invalid tool progress: %w", err)
	}
	if progress.CallID == nil || progress.Name == nil || progress.Phase == nil {
		return errors.New("invalid tool progress: missing callId, name, or phase")
	}
	if *progress.Phase != "running" && *progress.Phase != "generating" {
		return errors.New("invalid tool progress phase")
	}
	if progress.Intent != nil && (progress.Intent.Kind == nil || progress.Intent.Target == nil) {
		return errors.New("invalid tool progress intent")
	}
	if progress.Code != nil && (progress.Code.Text == nil || progress.Code.Offset == nil) {
		return errors.New("invalid tool progress code")
	}
	return nil
}
