package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"unicode/utf8"

	"albedo/cli/internal/daemon/protocol"
)

type streamBatch struct {
	Generation string            `json:"generation"`
	Cursor     *int64            `json:"cursor"`
	Events     []json.RawMessage `json:"events"`
	Snapshot   json.RawMessage   `json:"snapshot"`
}

func (c *ChatClient) ResetStream() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.progressCallIDs = nil
	c.afterSeq = -1
	c.afterGeneration = ""
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
	if api, ok := errors.AsType[*APIError](err); ok {
		kind := StreamTerminal
		if api.StatusCode == 408 || api.StatusCode == 429 || api.StatusCode >= 500 {
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
func (c *ChatClient) Stream(ctx context.Context, tail int, onEvent func(StreamEvent) error) error {
	return c.StreamWithProgress(ctx, tail, onEvent, nil)
}
func (c *ChatClient) StreamWithProgress(ctx context.Context, tail int, onEvent func(StreamEvent) error, onBatchConsumed func()) error {
	defer func() {
		if ctx.Err() != nil {
			c.ResetStream()
		}
	}()
	c.mu.Lock()
	after, generation := c.afterSeq, c.afterGeneration
	c.mu.Unlock()
	params := protocol.GetSessionParams{Tail: new(int64(min(200, max(0, tail))))}
	if generation != "" {
		params.AfterGeneration = &generation
		params.AfterSeq = &after
	}
	err := scanEventStream(ctx, c.conn, operation{Name: "watch session", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewGetSessionRequest(base, c.agentID, &params)
	}, Policy: readRecovery}, streamLimits{requireSSE: true, lineBytes: 1048577, errorBytes: 65536}, func(scanner *bufio.Scanner) error { return c.readStream(ctx, scanner, onBatchConsumed, onEvent) })
	return classifyStreamFailure(err)
}

// SSE framing is independent of network fragmentation and supports multiline data.
func scanSSEFrames(ctx context.Context, scanner *bufio.Scanner, consume func([]byte) error) error {
	var data strings.Builder
	for scanner.Scan() {
		if err := ctx.Err(); err != nil {
			return err
		}
		line := scanner.Text()
		if line == "" {
			if data.Len() > 0 {
				payload := strings.TrimSuffix(data.String(), "\n")
				if !utf8.ValidString(payload) {
					return streamFailure(StreamProtocol, errors.New("SSE data is not UTF-8"))
				}
				if err := consume([]byte(payload)); err != nil {
					return err
				}
				data.Reset()
			}
			continue
		}
		if strings.HasPrefix(line, "data:") {
			fragment := strings.TrimPrefix(line, "data:")
			fragment = strings.TrimPrefix(fragment, " ")
			if data.Len()+len(fragment)+1 > 1048577 {
				return streamFailure(StreamProtocol, errors.New("SSE frame exceeds 1 MiB"))
			}
			data.WriteString(fragment)
			data.WriteByte('\n')
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	if data.Len() != 0 {
		return io.ErrUnexpectedEOF
	}
	return nil
}
func (c *ChatClient) readStream(ctx context.Context, scanner *bufio.Scanner, onBatchConsumed func(), onEvent func(StreamEvent) error) error {
	return scanSSEFrames(ctx, scanner, func(payload []byte) error {
		var batch streamBatch
		if err := decodeRequired(payload, &batch, "generation", "cursor", "events"); err != nil {
			return streamFailure(StreamProtocol, err)
		}
		if !validGeneration(batch.Generation) || batch.Cursor == nil || *batch.Cursor < 0 || batch.Events == nil || len(batch.Events) > 256 {
			return streamFailure(StreamProtocol, fieldError("stream batch"))
		}
		var first sessionEventEnvelope
		if len(batch.Events) > 0 {
			if err := json.Unmarshal(batch.Events[0], &first); err != nil {
				return streamFailure(StreamProtocol, err)
			}
		}
		if first.Type == "failure" {
			if len(batch.Events) != 1 || batch.Snapshot != nil {
				return streamFailure(StreamProtocol, fieldError("failure batch"))
			}
			var reason protocol.SafeReason
			if err := json.Unmarshal(first.Data, &reason); err != nil || reason.Code == "" {
				return streamFailure(StreamProtocol, fieldError("failure reason"))
			}
			return streamFailure(StreamTerminal, &APIError{Code: reason.Code, Message: reason.Detail})
		}
		reset := first.Type == "reset"
		c.mu.Lock()
		previous, generation := c.afterSeq, c.afterGeneration
		c.mu.Unlock()
		sequence := previous
		var events []wireChatEvent
		var current []ToolProgress
		if reset {
			snapshot, err := decodeSession(batch.Snapshot)
			if err != nil {
				return streamFailure(StreamProtocol, err)
			}
			if snapshot.ID != c.agentID || snapshot.wire.Cursor.Generation != batch.Generation {
				return streamFailure(StreamProtocol, fieldError("snapshot identity"))
			}
			sequence = snapshot.wire.Cursor.Sequence
			before := int64(0)
			if len(snapshot.wire.History.Items) > 0 {
				before = snapshot.wire.History.Items[0].Position
			}
			events = append(events, wireChatEvent{StreamEvent: StreamEvent{Type: EventReset, Before: before, More: snapshot.wire.History.Older != nil, Snapshot: &snapshot}})
			hydrated, err := hydrateHistory(ctx, c.conn, c.agentID, snapshot.wire.History.Items)
			if err != nil {
				return streamFailure(StreamTransient, err)
			}
			history, err := historyEvents(hydrated)
			if err != nil {
				return streamFailure(StreamProtocol, err)
			}
			for _, event := range history {
				events = append(events, wireChatEvent{StreamEvent: event})
			}
			events = append(events, wireChatEvent{StreamEvent: StreamEvent{Type: EventUsage, Usage: usageValue(snapshot.wire.Usage), Replayed: true}})
			for _, progress := range snapshot.wire.CurrentProgress {
				raw, _ := json.Marshal(progress)
				parsed, err := decodeToolProgress(raw)
				if err != nil || parsed == nil {
					return streamFailure(StreamProtocol, fieldError("current progress"))
				}
				current = append(current, *parsed)
				events = append(events, wireChatEvent{StreamEvent: StreamEvent{Type: EventToolProgress, Progress: parsed}})
			}
		} else if batch.Snapshot != nil || generation == "" || generation != batch.Generation {
			return streamFailure(StreamProtocol, errors.New("initial or changed generation requires a snapshot reset"))
		}
		for index, raw := range batch.Events {
			var envelope sessionEventEnvelope
			if err := json.Unmarshal(raw, &envelope); err != nil {
				return streamFailure(StreamProtocol, err)
			}
			if reset && index == 0 {
				if _, err := decodeChatEvent(raw); err != nil {
					return streamFailure(StreamProtocol, err)
				}
				continue
			}
			if envelope.Type == "reset" || envelope.Type == "failure" || envelope.Sequence == nil || *envelope.Sequence != sequence+1 {
				return streamFailure(StreamProtocol, errors.New("stream events are not contiguous"))
			}
			sequence = *envelope.Sequence
			raw, err := hydrateSessionEvent(ctx, c.conn, c.agentID, raw)
			if err != nil {
				return classifyStreamFailure(err)
			}
			event, err := decodeChatEvent(raw)
			if err != nil {
				return streamFailure(StreamProtocol, err)
			}
			if event != nil {
				events = append(events, *event)
			}
		}
		if sequence != *batch.Cursor {
			return streamFailure(StreamProtocol, errors.New("batch cursor does not cover its events"))
		}
		active, err := c.nextProgressCallIDs(current, events, reset)
		if err != nil {
			return streamFailure(StreamProtocol, err)
		}
		for _, event := range events {
			if err := onEvent(event.StreamEvent); err != nil {
				return streamFailure(StreamTerminal, err)
			}
		}
		c.mu.Lock()
		c.progressCallIDs = active
		c.afterSeq = *batch.Cursor
		c.afterGeneration = batch.Generation
		c.mu.Unlock()
		if onBatchConsumed != nil {
			onBatchConsumed()
		}
		return nil
	})
}
func (c *ChatClient) nextProgressCallIDs(snapshot []ToolProgress, events []wireChatEvent, reset bool) (map[string]struct{}, error) {
	active := map[string]struct{}{}
	if reset {
		for _, progress := range snapshot {
			if _, ok := active[progress.CallID]; ok {
				return nil, errors.New("duplicate progress call")
			}
			active[progress.CallID] = struct{}{}
		}
	} else {
		c.mu.Lock()
		for id := range c.progressCallIDs {
			active[id] = struct{}{}
		}
		c.mu.Unlock()
	}
	for _, event := range events {
		if event.Replayed {
			continue
		}
		switch event.Type {
		case EventRetry, EventUser, EventMessage, EventError, EventInterrupted, EventTurnCompleted:
			clear(active)
		case EventToolProgress:
			if event.Progress == nil {
				clear(active)
			} else {
				active[event.Progress.CallID] = struct{}{}
			}
		case EventTool:
			delete(active, event.ProgressCallID)
		}
		if len(active) > 32 {
			return nil, errors.New("too many active progress calls")
		}
	}
	if len(active) > 32 {
		return nil, errors.New("too many active progress calls")
	}
	return active, nil
}
