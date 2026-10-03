package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"slices"
	"strings"
)

// wireChatEvent decodes tool arguments and optional display traces separately.
type wireChatEvent struct {
	CallID  string          `json:"callId"`
	Args    json.RawMessage `json:"args"`
	Elapsed json.RawMessage `json:"elapsedMs"`
	Trace   json.RawMessage `json:"trace"`
	StreamEvent
}

func decodeChatEvent(data json.RawMessage) (*wireChatEvent, error) {
	var header struct {
		Type EventType `json:"type"`
	}
	if err := json.Unmarshal(data, &header); err != nil {
		return nil, fmt.Errorf("invalid event: %w", err)
	}
	if header.Type == "" {
		return nil, errors.New("invalid event: missing or empty type")
	}
	switch header.Type {
	case EventText, EventReset, EventRetry, EventError, EventInterrupted, EventMessage, EventUser, EventThinking, EventNote, EventCompacted, EventToolProgress, EventTool, EventUsage, EventCommitted, EventTurnMembership, EventTurnCompleted, "turn_started":
	default:
		return nil, nil
	}
	var event wireChatEvent
	if err := json.Unmarshal(data, &event); err != nil {
		return nil, fmt.Errorf("invalid %s event: %w", header.Type, err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return nil, err
	}
	require := func(names ...string) error {
		for _, name := range names {
			value, exists := fields[name]
			if !exists || string(value) == "null" {
				return fmt.Errorf("invalid %s event: missing %s", header.Type, name)
			}
		}
		return nil
	}
	var err error
	switch header.Type {
	case EventText, EventMessage, EventUser, EventThinking, EventNote, EventError:
		err = require("text")
		if header.Type == EventMessage {
			err = require("text", "role")
			if event.Role != "assistant" {
				return nil, errors.New("invalid message event: role must be assistant")
			}
		}
		if header.Type == EventUser {
			err = require("text", "source", "triggeredAt")
		}
	case EventTurnMembership:
		err = require("turnId", "submissionIds")
		if event.TurnID == "" || event.SubmissionIDs == nil || slices.Contains(event.SubmissionIDs, "") {
			return nil, errors.New("invalid turn membership identity")
		}
	case EventTurnCompleted:
		err = require("turnId")
		if event.TurnID == "" {
			return nil, errors.New("invalid empty turn identity")
		}
	case EventReset:
		if raw, ok := fields["before"]; ok && string(raw) == "null" {
			return nil, errors.New("invalid reset before")
		}
		if raw, ok := fields["more"]; ok && string(raw) == "null" {
			return nil, errors.New("invalid reset more")
		}
	case EventCommitted:
		err = require("seq")
		if event.Seq <= 0 {
			err = errors.New("invalid committed event: seq must be positive")
		}
	case EventCompacted:
		err = require("evicted", "summary")
		if event.Evicted < 0 || event.Evicted > 1000000 || len(event.Summary) > 60000 {
			err = errors.New("invalid compacted event")
		}
	case EventTool:
		err = require("callId", "name", "args", "result")
		if event.CallID == "" || event.ToolName == "" {
			return nil, errors.New("invalid tool identity")
		}
		if len(event.Args) != 0 && string(event.Args) != "null" {
			var encoded string
			if decodeErr := json.Unmarshal(event.Args, &encoded); decodeErr != nil {
				return nil, fmt.Errorf("invalid tool args: %w", decodeErr)
			}
			// Tool arguments are model-generated text, not protocol-owned JSON.
			if json.Unmarshal([]byte(encoded), &event.ToolArgs) != nil {
				event.ToolArgs = map[string]any{}
			}
		}
	case EventUsage:
		var usage Usage
		if decodeErr := json.Unmarshal(data, &usage); decodeErr != nil {
			return nil, fmt.Errorf("invalid usage event: %w", decodeErr)
		}
		if fieldErr := require("model", "recordedAt"); fieldErr != nil {
			return nil, fieldErr
		}
		if usage.RecordedAt == nil || *usage.RecordedAt < 0 {
			return nil, errors.New("invalid usage timestamp")
		}
		for _, count := range []*int{usage.PromptTokens, usage.CachedPromptTokens, usage.CacheWriteTokens, usage.CompletionTokens, usage.TotalTokens} {
			if count != nil && *count < 0 {
				return nil, errors.New("invalid usage token count")
			}
		}
		if usage.ElapsedMs != nil && *usage.ElapsedMs < 0 || usage.TokensPerSecond != nil && *usage.TokensPerSecond < 0 {
			return nil, errors.New("invalid usage rate or duration")
		}
		for _, step := range usage.CacheFade {
			if step.At < 0 || step.Cached != nil && *step.Cached < 0 {
				return nil, errors.New("invalid cache fade")
			}
		}
		event.Usage = &usage
	case EventToolProgress:
		if len(data) > 8*1024 {
			return nil, errors.New("invalid tool_progress event: exceeds 8 KiB")
		}
		progress, fieldErr := decodeToolProgress(fields["progress"])
		if fieldErr != nil {
			return nil, fieldErr
		}
		event.Progress = progress
	}
	if err != nil {
		return nil, err
	}
	if event.Type != EventUsage && len(event.Elapsed) != 0 {
		if err := json.Unmarshal(event.Elapsed, &event.ElapsedMs); err != nil {
			return nil, fmt.Errorf("invalid elapsedMs: %w", err)
		}
	}
	if event.Timestamp != nil && *event.Timestamp < 0 || event.ElapsedMs < 0 || event.Before < 0 {
		return nil, errors.New("invalid event timestamp, elapsed time, or history cursor")
	}
	if event.Image != nil {
		event.Image = ParseImageMetadata(event.Image)
		if event.Image == nil {
			return nil, errors.New("invalid image metadata")
		}
	}
	if len(event.Trace) != 0 && string(event.Trace) != "null" {
		// Display-only evidence must not prevent loading the saved conversation.
		event.ToolTrace = ParseToolTrace(event.Trace)
	}
	return &event, nil
}

// ResetStream starts the next stream from a fresh snapshot. Call it after the
// subscription has stopped writing.
func (c *ChatClient) ResetStream() {
	c.mu.Lock()
	c.progressCallIDs = nil
	c.afterSeq = -1
	c.afterGeneration = ""
	c.mu.Unlock()
}

type streamBatch struct {
	Generation      string            `json:"generation"`
	Cursor          *int64            `json:"cursor"`
	Events          []json.RawMessage `json:"events"`
	CurrentProgress json.RawMessage   `json:"currentProgress"`
}

func streamFailure(kind StreamFailureKind, cause error) error {
	return &StreamError{Kind: kind, Cause: cause}
}

func classifyStreamFailure(err error) error {
	if err == nil {
		return nil
	}
	if _, ok := errors.AsType[*StreamError](err); ok {
		return err
	}
	if apiErr, ok := errors.AsType[*APIError](err); ok {
		kind := StreamTerminal
		if apiErr.StatusCode == http.StatusRequestTimeout || apiErr.StatusCode == http.StatusTooManyRequests || apiErr.StatusCode >= 500 {
			kind = StreamTransient
		}
		return streamFailure(kind, err)
	}
	if errors.Is(err, bufio.ErrTooLong) {
		return streamFailure(StreamProtocol, err)
	}
	if _, ok := errors.AsType[net.Error](err); ok {
		return streamFailure(StreamTransient, err)
	}
	if isConnectionError(err) || errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return streamFailure(StreamTransient, err)
	}
	return streamFailure(StreamTerminal, err)
}

// Stream uses ctx for cancellation; onEvent must also honor ctx if it blocks.
func (c *ChatClient) Stream(ctx context.Context, tail int, onEvent func(StreamEvent) error) error {
	return c.StreamWithProgress(ctx, tail, onEvent, nil)
}

// StreamWithProgress reports fully consumed batches, including ignored additive
// events, so subscribers can reset their reconnect backoff after progress.
func (c *ChatClient) StreamWithProgress(ctx context.Context, tail int, onEvent func(StreamEvent) error, onBatchConsumed func()) error {
	defer func() {
		// Cancellation also clears state when the request fails before reading.
		// Transient failures and EOF retain the last consumed cursor.
		if ctx.Err() != nil {
			c.ResetStream()
		}
	}()
	if err := checkCapability(ctx, c.conn, "normalized_tool_progress", "normalized tool progress for session streams"); err != nil {
		return err
	}

	c.mu.Lock()
	afterSeq, afterGeneration := c.afterSeq, c.afterGeneration
	c.mu.Unlock()

	query := url.Values{}
	if afterGeneration != "" {
		query.Set("after_generation", afterGeneration)
		query.Set("after_seq", fmt.Sprint(afterSeq))
	}
	if tail > 0 {
		query.Set("tail", fmt.Sprint(tail))
	}

	route := "/stream?" + query.Encode()
	subscription := operation{Name: "stream session", Method: http.MethodGet, Path: sessionPath(c.agentID, route), Policy: readRecovery}
	err := scanEventStream(ctx, c.conn, subscription, streamLimits{requireSSE: true, lineBytes: 10 * 1024 * 1024, errorBytes: 64 * 1024}, func(scanner *bufio.Scanner) error {
		return c.readStream(ctx, scanner, onBatchConsumed, func(event StreamEvent) error {
			if err := onEvent(event); err != nil {
				return streamFailure(StreamTerminal, err)
			}
			return nil
		})
	})
	return classifyStreamFailure(err)
}

func (c *ChatClient) readStream(ctx context.Context, scanner *bufio.Scanner, onBatchConsumed func(), onEvent func(StreamEvent) error) error {
	var eventType string
	for scanner.Scan() {
		if err := ctx.Err(); err != nil {
			return err
		}
		line := scanner.Text()
		if line == "" {
			eventType = ""
			continue
		}
		if strings.HasPrefix(line, "event:") {
			eventType = strings.TrimSpace(line[6:])
			continue
		}
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		payload := strings.TrimSpace(line[5:])
		if payload == "" {
			continue
		}
		if eventType == "error" {
			var failure struct {
				Error string `json:"error"`
				Text  string `json:"text"`
			}
			if err := json.Unmarshal([]byte(payload), &failure); err != nil {
				return streamFailure(StreamProtocol, fmt.Errorf("invalid stream error: %w", err))
			}
			if failure.Error != "" {
				return streamFailure(StreamTerminal, errors.New(failure.Error))
			}
			if failure.Text != "" {
				return streamFailure(StreamTerminal, errors.New(failure.Text))
			}
			return streamFailure(StreamProtocol, errors.New("invalid stream error: missing error or text"))
		}
		var batch streamBatch
		if err := json.Unmarshal([]byte(payload), &batch); err != nil {
			return streamFailure(StreamProtocol, fmt.Errorf("invalid stream batch: %w", err))
		}
		if batch.Generation == "" || batch.Cursor == nil || *batch.Cursor < 0 || batch.Events == nil {
			return streamFailure(StreamProtocol, errors.New("invalid stream batch: missing generation, cursor, or events"))
		}
		// Validate the whole batch before delivering events or changing preview state.
		events := make([]wireChatEvent, 0, len(batch.Events))
		for index, raw := range batch.Events {
			event, err := decodeChatEvent(raw)
			if err != nil {
				return streamFailure(StreamProtocol, err)
			}
			if event != nil {
				if event.Type == EventReset && index != 0 {
					return streamFailure(StreamProtocol, errors.New("reset must begin its batch"))
				}
				events = append(events, *event)
			}
		}
		reset := len(events) > 0 && events[0].Type == EventReset
		for _, event := range events {
			if !reset && event.Type == EventTool && event.ProgressCallID == "" {
				return streamFailure(StreamProtocol, errors.New("invalid live tool event: missing progressCallId"))
			}
		}
		currentProgress, err := decodeCurrentProgress(batch.CurrentProgress, reset)
		if err != nil {
			return streamFailure(StreamProtocol, err)
		}
		progressCallIDs, err := c.nextProgressCallIDs(currentProgress, events, reset)
		if err != nil {
			return streamFailure(StreamProtocol, err)
		}
		c.mu.Lock()
		previous, generation := c.afterSeq, c.afterGeneration
		c.mu.Unlock()
		if generation != batch.Generation && !reset {
			return streamFailure(StreamProtocol, errors.New("initial or changed generation stream must begin with reset"))
		}
		if generation == batch.Generation && *batch.Cursor < previous && !reset {
			return streamFailure(StreamProtocol, errors.New("stream cursor regressed without reset"))
		}
		for _, event := range events {
			if event.Type == "turn_started" {
				continue
			}
			event.Replayed = reset && event.Type != EventReset
			if err := onEvent(event.StreamEvent); err != nil {
				return err
			}
		}
		for index := range currentProgress {
			if err := onEvent(StreamEvent{Type: EventToolProgress, Progress: &currentProgress[index]}); err != nil {
				return err
			}
		}
		c.mu.Lock()
		c.progressCallIDs = progressCallIDs
		c.afterSeq = *batch.Cursor
		c.afterGeneration = batch.Generation
		c.mu.Unlock()
		if onBatchConsumed != nil {
			onBatchConsumed()
		}
	}
	return nil
}

func (c *ChatClient) nextProgressCallIDs(snapshot []ToolProgress, events []wireChatEvent, reset bool) (map[string]struct{}, error) {
	active := make(map[string]struct{})
	if reset {
		for _, progress := range snapshot {
			active[progress.CallID] = struct{}{}
		}
		return active, nil
	}
	c.mu.Lock()
	for callID := range c.progressCallIDs {
		active[callID] = struct{}{}
	}
	c.mu.Unlock()
	for _, event := range events {
		switch event.Type {
		case EventRetry, EventUser, EventMessage, EventError, EventInterrupted, EventTurnCompleted:
			clear(active)
		case EventToolProgress:
			if event.Progress == nil {
				clear(active)
			} else {
				active[event.Progress.CallID] = struct{}{}
				if len(active) > maxActiveToolProgress {
					return nil, errors.New("too many active tool progress calls")
				}
			}
		case EventTool:
			delete(active, event.ProgressCallID)
		}
	}
	return active, nil
}

func decodeCurrentProgress(raw json.RawMessage, reset bool) ([]ToolProgress, error) {
	if !reset {
		if raw != nil {
			return nil, errors.New("invalid incremental stream batch: currentProgress is only valid on reset")
		}
		return nil, nil
	}
	if raw == nil || string(raw) == "null" {
		return nil, errors.New("invalid reset stream batch: missing currentProgress array")
	}
	var entries []json.RawMessage
	if err := json.Unmarshal(raw, &entries); err != nil || entries == nil {
		return nil, errors.New("invalid reset stream batch: currentProgress must be an array")
	}
	progresses := make([]ToolProgress, 0, len(entries))
	if len(entries) > maxActiveToolProgress {
		return nil, errors.New("invalid reset stream batch: too many active tool progress calls")
	}
	for _, entry := range entries {
		progress, err := decodeToolProgress(entry)
		if err != nil {
			return nil, fmt.Errorf("invalid reset currentProgress: %w", err)
		}
		if progress == nil {
			return nil, errors.New("invalid reset currentProgress: entries must be progress objects")
		}
		for _, existing := range progresses {
			if existing.CallID == progress.CallID {
				return nil, fmt.Errorf("invalid reset currentProgress: duplicate callId %q", progress.CallID)
			}
		}
		progresses = append(progresses, *progress)
	}
	return progresses, nil
}
