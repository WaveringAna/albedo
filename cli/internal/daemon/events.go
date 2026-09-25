package daemon

import (
	"encoding/json"
	"strings"
	"unicode"
)

// Display-only execution evidence, never appended to the model's tool output.
type ToolActivity struct {
	Kind   string `json:"kind"` // "read" | "search" | "list" | "run"
	Target string `json:"target"`
	Failed bool   `json:"failed,omitempty"`
}

type FileChange struct {
	Path    string `json:"path"`
	Kind    string `json:"kind"` // "diff" | "unavailable"
	Diff    string `json:"diff,omitempty"`
	Added   int    `json:"added,omitempty"`
	Removed int    `json:"removed,omitempty"`
	Reason  string `json:"reason,omitempty"`
}

type ToolTrace struct {
	Activities []ToolActivity `json:"activities"`
	Changes    []FileChange   `json:"changes"`
	Truncated  bool           `json:"truncated,omitempty"`
}

func isSafeText(s string, limit int) bool {
	return len(s) <= limit
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
		if !isSafeText(act.Target, 1000) {
			return nil
		}
	}

	for _, ch := range trace.Changes {
		if !isSafeText(ch.Path, 1000) {
			return nil
		}
		if ch.Kind == "unavailable" {
			if !isSafeText(ch.Reason, 1000) {
				return nil
			}
		} else if ch.Kind == "diff" {
			if !isSafeText(ch.Diff, 16000) || ch.Added < 0 || ch.Removed < 0 {
				return nil
			}
		} else {
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

type ToolCodePreview struct {
	Offset int    `json:"offset"`
	Text   string `json:"text"`
}

type ToolProgress struct {
	CallID string           `json:"callId"`
	Name   string           `json:"name"`
	Phase  string           `json:"phase"` // "generating" | "running"
	Intent *ToolIntent      `json:"intent,omitempty"`
	Code   *ToolCodePreview `json:"code,omitempty"`
}

type EventType string

const (
	EventReset        EventType = "reset"
	EventRetry        EventType = "retry"
	EventText         EventType = "text"
	EventError        EventType = "error"
	EventInterrupted  EventType = "interrupted"
	EventMessage      EventType = "message"
	EventUser         EventType = "user"
	EventThinking     EventType = "thinking"
	EventNote         EventType = "note"
	EventCompacted    EventType = "compacted"
	EventToolProgress EventType = "tool_progress"
	EventTool         EventType = "tool"
	EventUsage        EventType = "usage"
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
}

type StreamEvent struct {
	Type        EventType      `json:"type"`
	Text        string         `json:"text,omitempty"`
	Role        string         `json:"role,omitempty"` // "assistant"
	Timestamp   *int64         `json:"timestamp,omitempty"`
	Source      string         `json:"source,omitempty"`
	TriggeredAt string         `json:"triggeredAt,omitempty"`
	ClientID    string         `json:"clientId,omitempty"`
	Image       *ImageMetadata `json:"image,omitempty"`
	Evicted     int            `json:"evicted,omitempty"`
	Summary     string         `json:"summary,omitempty"`
	Progress    *ToolProgress  `json:"progress,omitempty"`
	ToolName    string         `json:"name,omitempty"`
	ToolArgs    map[string]any `json:"args,omitempty"`
	ToolResult  string         `json:"result,omitempty"`
	ToolTrace   *ToolTrace     `json:"trace,omitempty"`
	Usage       *Usage         `json:"usage,omitempty"`
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
