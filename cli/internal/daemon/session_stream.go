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
	case EventText, EventReset, EventRetry, EventError, EventInterrupted, EventMessage, EventUser, EventThinking, EventNote, EventCompacted, EventToolProgress, EventTool, EventUsage, EventCommitted, EventTurnMembership, EventTurnCompleted, "arguments_delta", "turn_started":
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
	case "arguments_delta":
		err = require("callId", "name", "text")
		if event.CallID == "" || event.ToolName == "" {
			return nil, errors.New("invalid argument delta identity")
		}
	case EventTurnMembership:
		err = require("turnId", "submissionIds")
		if event.TurnID == "" || event.SubmissionIDs == nil {
			return nil, errors.New("invalid turn membership identity")
		}
		for _, id := range event.SubmissionIDs {
			if id == "" {
				return nil, errors.New("invalid empty submission identity")
			}
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
		if fieldErr := validateToolProgress(fields["progress"]); fieldErr != nil {
			return nil, fieldErr
		}
		if progress := event.Progress; progress != nil {
			if progress.CallID == "" || progress.Name == "" || len(progress.CallID) > 200 || len(progress.Name) > 100 {
				return nil, errors.New("invalid tool progress event")
			}
			progress.Name = cleanLabel(progress.Name)
			if intent := progress.Intent; intent != nil {
				if (intent.Kind != "write" && intent.Kind != "edit" && intent.Kind != "read" && intent.Kind != "run") || len(intent.Target) > 300 {
					return nil, errors.New("invalid tool progress intent")
				}
			}
			if code := progress.Code; code != nil {
				if code.Offset < 0 || (progress.Phase == "generating" && len(code.Text) > 512) || len(code.Text) > 16000 {
					return nil, errors.New("invalid tool progress code")
				} else if progress.Phase == "running" {
					if progress.Intent == nil && progress.Name == "python" {
						progress.Intent = ParsePythonIntent(code.Text)
					}
					head, _, _ := strings.Cut(strings.TrimSpace(code.Text), "\n")
					progress.Code = &ToolCodePreview{Text: sanitizeControlRunes(head)}
				}
			}
		}
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

// ResetStream discards unfinished tool arguments and starts the next stream from
// a fresh snapshot. Call it after the subscription has stopped writing.
func (c *ChatClient) ResetStream() {
	c.mu.Lock()
	c.argumentsByCall = make(map[string]*strings.Builder)
	c.afterSeq = -1
	c.afterGeneration = ""
	c.mu.Unlock()
}

type streamBatch struct {
	Generation string            `json:"generation"`
	Cursor     *int64            `json:"cursor"`
	Events     []json.RawMessage `json:"events"`
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
		// Transient failures and EOF retain the cursor and unfinished arguments.
		if ctx.Err() != nil {
			c.ResetStream()
		}
	}()

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
	operation := operation{Name: "stream session", Method: http.MethodGet, Path: sessionPath(c.agentID, route), Policy: readRecovery}
	err := scanEventStream(ctx, c.conn, operation, streamLimits{requireSSE: true, lineBytes: 10 * 1024 * 1024, errorBytes: 64 * 1024}, func(scanner *bufio.Scanner) error {
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
	reporter := NewToolProgressReporter(func(progress *ToolProgress) error {
		return onEvent(StreamEvent{Type: EventToolProgress, Progress: progress})
	})
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
		c.mu.Lock()
		previous, generation := c.afterSeq, c.afterGeneration
		c.mu.Unlock()
		if generation != batch.Generation && !reset {
			return streamFailure(StreamProtocol, errors.New("initial or changed generation stream must begin with reset"))
		}
		if generation == batch.Generation && *batch.Cursor < previous && !reset {
			return streamFailure(StreamProtocol, errors.New("stream cursor regressed without reset"))
		}
		if err := c.validateArgumentBatch(events); err != nil {
			return streamFailure(StreamProtocol, err)
		}
		for _, event := range events {
			switch event.Type {
			case EventReset, EventRetry, "turn_started", EventMessage, EventInterrupted, EventError:
				c.mu.Lock()
				c.argumentsByCall = make(map[string]*strings.Builder)
				c.mu.Unlock()
				if err := reporter.Report(nil, "running"); err != nil {
					return err
				}
			}
			if event.Type == "turn_started" {
				continue
			}
			if event.Type == EventTool || (event.Type == EventToolProgress && event.Progress != nil && event.Progress.Phase == "running") {
				callID := event.CallID
				if event.Progress != nil {
					callID = event.Progress.CallID
				}
				c.mu.Lock()
				delete(c.argumentsByCall, callID)
				c.mu.Unlock()
				if err := reporter.Report(nil, "running"); err != nil {
					return err
				}
			}
			if event.Type == "arguments_delta" {
				if event.Text != "" {
					arguments := c.appendArguments(event.CallID, event.Text)
					call := &ToolCallAssembly{ID: event.CallID}
					call.Function.Name = event.ToolName
					call.Function.Arguments = arguments
					if err := reporter.Report(call, "generating"); err != nil {
						return err
					}
				}
				continue
			}
			event.Replayed = reset && event.Type != EventReset
			if err := onEvent(event.StreamEvent); err != nil {
				return err
			}
		}
		c.mu.Lock()
		c.afterSeq = *batch.Cursor
		c.afterGeneration = batch.Generation
		c.mu.Unlock()
		if onBatchConsumed != nil {
			onBatchConsumed()
		}
	}
	return nil
}

func (c *ChatClient) appendArguments(callID, text string) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	arguments, exists := c.argumentsByCall[callID]
	if !exists {
		arguments = new(strings.Builder)
		c.argumentsByCall[callID] = arguments
	}
	arguments.WriteString(text)
	return arguments.String()
}

// validateArgumentBatch checks preview limits before delivering any batch event.
func (c *ChatClient) validateArgumentBatch(events []wireChatEvent) error {
	sizes := make(map[string]int)
	c.mu.Lock()
	for id, args := range c.argumentsByCall {
		sizes[id] = args.Len()
	}
	c.mu.Unlock()
	for _, event := range events {
		switch event.Type {
		case EventReset, EventRetry, "turn_started", EventMessage, EventInterrupted, EventError:
			clear(sizes)
		case EventTool:
			delete(sizes, event.CallID)
		case EventToolProgress:
			if event.Progress != nil && event.Progress.Phase == "running" {
				delete(sizes, event.Progress.CallID)
			}
		case "arguments_delta":
			if event.Text == "" {
				continue
			}
			sizes[event.CallID] += len(event.Text)
			retained := 0
			for id, size := range sizes {
				retained += len(id) + size
			}
			if len(sizes) > 32 || retained > 2000000 {
				return errors.New("too many tool argument previews for this client to display")
			}
		}
	}
	return nil
}
