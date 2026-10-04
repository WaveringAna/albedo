package daemon

import (
	"encoding/json"
	"errors"
	"strings"

	"albedo/cli/internal/daemon/protocol"
)

type wireChatEvent struct {
	CallID string
	StreamEvent
}
type sessionEventEnvelope struct {
	Type     string          `json:"type"`
	Sequence *int64          `json:"sequence"`
	Data     json.RawMessage `json:"data"`
}

func decodeChatEvent(raw json.RawMessage) (*wireChatEvent, error) {
	var envelope sessionEventEnvelope
	if err := decodeRequired(raw, &envelope, "type", "data"); err != nil {
		return nil, err
	}
	return decodeChatEnvelope(envelope, len(raw), nil)
}

func decodeChatEnvelope(envelope sessionEventEnvelope, wireBytes int, content *eventContentReader) (*wireChatEvent, error) {
	if envelope.Type == "" || envelope.Data == nil || string(envelope.Data) == "null" {
		return nil, fieldError("event")
	}
	if envelope.Type != "reset" && envelope.Type != "failure" && (envelope.Sequence == nil || *envelope.Sequence < 1) {
		return nil, fieldError("event sequence")
	}
	event := StreamEvent{Type: EventType(envelope.Type)}
	switch envelope.Type {
	case "reset":
		var data struct {
			Reason string `json:"reason"`
		}
		if err := decodeRequired(envelope.Data, &data, "reason"); err != nil {
			return nil, err
		}
		switch data.Reason {
		case "initial", "generation_changed", "replay_unavailable", "recovery":
		default:
			return nil, fieldError("reset reason")
		}
	case "status":
		var data protocol.SessionStatus
		if err := decodeRequired(envelope.Data, &data); err != nil {
			return nil, err
		}
		if err := validateSessionStatus(data); err != nil {
			return nil, err
		}
		status := statusValue(data, protocol.Kernel{})
		event.Status = &status
	case "input":
		var data struct {
			Input protocol.Input `json:"input"`
		}
		if err := decodeRequired(envelope.Data, &data, "input"); err != nil {
			return nil, err
		}
		if err := validInput(data.Input); err != nil {
			return nil, err
		}
		receipt := InputReceipt(data.Input)
		event.Receipt = &receipt
		event.OperationID = data.Input.ID
		if data.Input.Turn != nil {
			event.Type = EventTurnMembership
			event.TurnID = data.Input.Turn.ID
			event.SubmissionIDs = []string{data.Input.ID}
		}
	case "text", "thinking":
		var data struct {
			RunID     string `json:"run_id"`
			MessageID string `json:"message_id"`
			ElapsedMs *int64 `json:"elapsed_ms"`
			Text      string `json:"text"`
		}
		if err := decodeRequired(envelope.Data, &data, "run_id", "message_id", "text"); err != nil {
			return nil, err
		}
		if data.RunID == "" || data.MessageID == "" {
			return nil, fieldError("message identity")
		}
		event.Text, event.TurnID, event.MessageID = data.Text, data.RunID, data.MessageID
		if data.ElapsedMs != nil {
			event.ElapsedMs = *data.ElapsedMs
			event.ElapsedObserved = true
		}
	case "message":
		var data struct {
			Entry protocol.HistoryEntry `json:"entry"`
		}
		if err := decodeRequired(envelope.Data, &data, "entry"); err != nil {
			return nil, err
		}
		if content != nil {
			entry, err := content.hydrateEntry(data.Entry)
			if err != nil {
				return nil, classifyStreamFailure(err)
			}
			data.Entry = entry
		}
		entries, err := historyEntryEvents(data.Entry)
		if err != nil {
			return nil, err
		}
		if len(entries) == 0 {
			return nil, nil
		}
		event = entries[0]
		event.Replayed = false
	case "note":
		var data struct {
			Text    string                 `json:"text"`
			EntryID string                 `json:"entry_id"`
			Origin  string                 `json:"origin"`
			Mail    *protocol.MailMetadata `json:"mail"`
		}
		if err := decodeRequired(envelope.Data, &data, "entry_id", "origin", "text", "mail"); err != nil {
			return nil, err
		}
		event.Text, event.Source = data.Text, data.Origin
	case "tool_progress":
		if wireBytes > 8192 {
			return nil, errors.New("tool_progress exceeds 8 KiB")
		}
		var data struct {
			Progress json.RawMessage `json:"progress"`
		}
		if err := decodeRequired(envelope.Data, &data, "progress"); err != nil {
			return nil, err
		}
		progress, err := decodeToolProgress(data.Progress)
		if err != nil {
			return nil, err
		}
		event.Progress = progress
	case "tool":
		var data toolEventData
		if err := decodeRequired(envelope.Data, &data, "tool_call_id", "progress_call_id", "name", "arguments", "result", "trace", "content_complete", "reference"); err != nil {
			return nil, err
		}
		if data.ToolCallID == "" || data.ProgressCallID == "" || data.Name == "" {
			return nil, fieldError("tool identity")
		}
		if content != nil {
			if err := content.hydrateTool(&data); err != nil {
				return nil, classifyStreamFailure(err)
			}
		}
		event.ToolName, event.ProgressCallID = data.Name, data.ProgressCallID
		arguments, _ := dynamicValue(data.Arguments)
		event.ToolArgs, _ = arguments.(map[string]any)
		if json.Unmarshal(data.Result, &event.ToolResult) != nil {
			event.ToolResult = string(data.Result)
		}
		event.ToolTrace = ParseToolTrace(data.Trace)
		return &wireChatEvent{CallID: data.ToolCallID, StreamEvent: event}, nil
	case "usage":
		var data protocol.Usage
		if err := decodeRequired(envelope.Data, &data); err != nil {
			return nil, err
		}
		event.Usage = usageValue(data)
	case "committed":
		var data struct {
			HighWater       int64    `json:"high_water"`
			ReplacesLiveIDs []string `json:"replaces_live_ids"`
			ReplacesAllLive bool     `json:"replaces_all_live"`
		}
		if err := decodeRequired(envelope.Data, &data, "high_water", "replaces_live_ids", "replaces_all_live"); err != nil {
			return nil, err
		}
		if data.HighWater < 0 {
			return nil, fieldError("history high water")
		}
		if data.ReplacesLiveIDs == nil || len(data.ReplacesLiveIDs) > 256 {
			return nil, fieldError("live replacement identities")
		}
		for _, id := range data.ReplacesLiveIDs {
			if id == "" {
				return nil, fieldError("live replacement identity")
			}
		}
		event.Seq, event.ReplacesLiveIDs = data.HighWater, data.ReplacesLiveIDs
		event.ReplacesAllLive = data.ReplacesAllLive
	case "turn_completed":
		var data struct {
			RunID      string   `json:"run_id"`
			State      string   `json:"state"`
			InputIDs   []string `json:"input_ids"`
			InputCount int64    `json:"input_count"`
			Truncated  bool     `json:"truncated"`
		}
		if err := decodeRequired(envelope.Data, &data, "run_id", "state", "input_ids", "input_count", "truncated"); err != nil {
			return nil, err
		}
		if data.RunID == "" || data.InputIDs == nil {
			return nil, fieldError("turn completion")
		}
		event.TurnID, event.SubmissionIDs = data.RunID, data.InputIDs
		if data.State == "interrupted" {
			event.Source = "interrupted"
		} else if data.State == "failed" || data.State == "abandoned" {
			event.Source = "failed"
		} else if data.State != "completed" {
			return nil, fieldError("turn state")
		}
	case "retry":
		var data struct {
			RunID  string              `json:"run_id"`
			Reason protocol.SafeReason `json:"reason"`
		}
		if err := decodeRequired(envelope.Data, &data, "run_id", "attempt", "reason", "delay_ms"); err != nil {
			return nil, err
		}
		event.TurnID, event.Text = data.RunID, data.Reason.Detail
	case "compacted":
		var data protocol.CompactionObservation
		if err := json.Unmarshal(envelope.Data, &data); err != nil {
			return nil, err
		}
		event.Evicted = int(data.EvictedEntries)
		event.Summary = data.Summary
		event.Strategy = value(data.Strategy)
	case "error":
		var data struct {
			RunID   *string `json:"run_id"`
			Code    string  `json:"code"`
			Message string  `json:"message"`
		}
		if err := decodeRequired(envelope.Data, &data, "run_id", "code", "message"); err != nil {
			return nil, err
		}
		if data.Code == "history_publication_failed" {
			return nil, &APIError{StatusCode: 503, Code: data.Code, Message: data.Message}
		}
		event.Text, event.TurnID = data.Message, value(data.RunID)
	case "invalidate":
		var data struct {
			Kind string `json:"kind"`
			URL  string `json:"url"`
		}
		if err := decodeRequired(envelope.Data, &data, "kind", "url"); err != nil {
			return nil, err
		}
		var resources ResourceInvalidation
		switch data.Kind {
		case "session":
			resources.Session = true
		case "settings":
			resources.Settings = true
		case "catalog":
			resources.Catalog = true
		case "context":
			resources.Context = true
		case "extension":
			resources.Extension = true
		default:
			return nil, fieldError("invalidation kind")
		}
		if !strings.HasPrefix(data.URL, "/") || strings.HasPrefix(data.URL, "//") {
			return nil, fieldError("invalidation URL")
		}
		event.Invalidation = &resources
	case "failure":
		return nil, errors.New("failure must be a terminal batch")
	default:
		return nil, nil
	}
	return &wireChatEvent{StreamEvent: event}, nil
}

type toolEventData struct {
	Reference       *protocol.ContentReference `json:"reference"`
	ToolCallID      string                     `json:"tool_call_id"`
	ProgressCallID  string                     `json:"progress_call_id"`
	Name            string                     `json:"name"`
	Arguments       json.RawMessage            `json:"arguments"`
	Result          json.RawMessage            `json:"result"`
	Trace           json.RawMessage            `json:"trace"`
	ContentComplete bool                       `json:"content_complete"`
}
