package daemon

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

type AgentPhase string

const (
	PhaseResting    AgentPhase = "resting"
	PhasePreparing  AgentPhase = "preparing"
	PhaseReasoning  AgentPhase = "reasoning"
	PhaseTool       AgentPhase = "tool"
	PhaseWaiting    AgentPhase = "waiting"
	PhaseCompacting AgentPhase = "compacting"
)

var validAgentPhases = map[AgentPhase]bool{
	PhaseResting:    true,
	PhasePreparing:  true,
	PhaseReasoning:  true,
	PhaseTool:       true,
	PhaseWaiting:    true,
	PhaseCompacting: true,
}

type AgentStatus struct {
	Phase   *AgentPhase `json:"phase,omitempty"`
	Running bool        `json:"running"`
	Idle    bool        `json:"idle"`
}

type WorkspaceMissingError struct {
	Workspace string
}

func (e *WorkspaceMissingError) Error() string {
	return "workspace folder not found: " + e.Workspace
}

type SendResult struct {
	OK     bool `json:"ok"`
	Queued bool `json:"queued"`
}

type ChatClient struct {
	conn            *Connection
	argumentsByCall map[string]*strings.Builder
	agentID         string
	clientID        string
	afterSeq        int
	mu              sync.Mutex
}

// NewChatClient shares conn's HTTP transport. A nil connection panics.
func NewChatClient(conn *Connection, agentID string) *ChatClient {
	if conn == nil {
		panic("daemon.NewChatClient: nil connection")
	}
	identity := make([]byte, 16)
	_, _ = rand.Read(identity)
	return &ChatClient{
		conn:            conn,
		agentID:         strings.TrimSpace(agentID),
		clientID:        "cli-" + hex.EncodeToString(identity),
		afterSeq:        -1,
		argumentsByCall: make(map[string]*strings.Builder),
	}
}

func (c *ChatClient) ClientID() string {
	return c.clientID
}

func (c *ChatClient) agentPath(path string) string {
	return fmt.Sprintf("/sessions/%s%s", url.PathEscape(c.agentID), path)
}

func (c *ChatClient) submitPayload(ctx context.Context, payload map[string]any) (*SendResult, error) {
	reqCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()

	if c.clientID != "" {
		payload["clientId"] = c.clientID
	}

	result, err := Submit(reqCtx, c.conn, c.agentID, payload)
	if err != nil {
		return nil, err
	}
	return &result, nil
}

func (c *ChatClient) Send(ctx context.Context, content string, image *ImageAttachment) (*SendResult, error) {
	payload := map[string]any{
		"content": content,
	}
	if image != nil {
		payload["image"] = image
	}
	return c.submitPayload(ctx, payload)
}

func (c *ChatClient) Continue(ctx context.Context) (*SendResult, error) {
	return c.submitPayload(ctx, map[string]any{
		"type": "continue",
	})
}

func (c *ChatClient) Interrupt(ctx context.Context) (bool, error) {
	reqCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	return InterruptSession(reqCtx, c.conn, c.agentID)
}

// HistoryPage is older transcript, rendered as the stream renders a reset.
type HistoryPage struct {
	Events []StreamEvent
	Before int64 // first row of the page: the cursor for the next older one
	More   bool
}

// History returns up to rows transcript rows before the given row, oldest
// first, widened back to the start of a turn.
func (c *ChatClient) History(ctx context.Context, before int64, rows int) (*HistoryPage, error) {
	reqCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	route := fmt.Sprintf("/history?rows=%d", rows)
	if before > 0 {
		route += fmt.Sprintf("&before=%d", before)
	}
	operation := Operation{Name: "read history", Method: http.MethodGet, Path: c.agentPath(route), Body: nil, Policy: ReadRecovery}
	body, err := requestBytes(reqCtx, c.conn, operation, responseLimits{successStatus: http.StatusOK, bodyBytes: 32 * 1024 * 1024, errorBytes: 64 * 1024})
	if err != nil {
		return nil, err
	}

	var data struct {
		Before *int64            `json:"before"`
		More   *bool             `json:"more"`
		Events []json.RawMessage `json:"events"`
	}
	if err := json.Unmarshal(body, &data); err != nil {
		return nil, err
	}
	if data.Events == nil || data.Before == nil || data.More == nil || *data.Before < 0 {
		return nil, errors.New("invalid history page: missing events, before, or more")
	}
	page := &HistoryPage{Before: *data.Before, More: *data.More}
	for _, raw := range data.Events {
		event, err := decodeChatEvent(raw)
		if err != nil {
			return nil, err
		}
		if event != nil {
			event.Replayed = true
			page.Events = append(page.Events, event.StreamEvent)
		}
	}
	return page, nil
}

// ContextWindow reads the model's context window from the session's last
// prepared request. It is nil when neither a catalog nor the configuration
// knows it, or when no request has been prepared yet.
func (c *ChatClient) ContextWindow(ctx context.Context) (*int, error) {
	reqCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	operation := Operation{Name: "read context", Method: http.MethodGet, Path: c.agentPath("/context"), Body: nil, Policy: ReadRecovery}
	body, err := requestBytes(reqCtx, c.conn, operation, responseLimits{successStatus: http.StatusOK, bodyBytes: 1024 * 1024, errorBytes: 64 * 1024})
	if err != nil {
		return nil, err
	}

	var data struct {
		Window *int `json:"context_window_tokens"`
	}
	if err := json.Unmarshal(body, &data); err != nil {
		return nil, err
	}
	if data.Window != nil && *data.Window <= 0 {
		return nil, nil
	}
	return data.Window, nil
}

func (c *ChatClient) GetStatus(ctx context.Context) (*AgentStatus, error) {
	reqCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()

	operation := Operation{Name: "read status", Method: http.MethodGet, Path: c.agentPath("/status"), Body: nil, Policy: ReadRecovery}
	body, err := requestBytes(reqCtx, c.conn, operation, responseLimits{successStatus: http.StatusOK, bodyBytes: 64 * 1024, errorBytes: 64 * 1024})
	if err != nil {
		return nil, err
	}

	var data struct {
		Phase   *string `json:"phase"`
		Running bool    `json:"running"`
		Idle    bool    `json:"idle"`
	}
	if err := json.Unmarshal(body, &data); err != nil {
		return nil, err
	}

	var phase *AgentPhase
	if data.Phase != nil {
		p := AgentPhase(*data.Phase)
		if validAgentPhases[p] {
			phase = &p
		}
	}

	return &AgentStatus{
		Running: data.Running,
		Idle:    data.Idle,
		Phase:   phase,
	}, nil
}

// wireChatEvent keeps arbitrary tool arguments separate from protocol fields.
type wireChatEvent struct {
	CallID  string          `json:"callId"`
	Args    json.RawMessage `json:"args"`
	Elapsed json.RawMessage `json:"elapsedMs"`
	StreamEvent
}

func decodeChatEvent(data json.RawMessage) (*wireChatEvent, error) {
	var header struct {
		Type EventType `json:"type"`
	}
	if err := json.Unmarshal(data, &header); err != nil {
		return nil, fmt.Errorf("invalid event: %w", err)
	}
	switch header.Type {
	case "", EventText, EventReset, EventRetry, EventError, EventInterrupted, EventMessage, EventUser, EventThinking, EventNote, EventCompacted, EventToolProgress, EventTool, EventUsage, EventCommitted, EventTurnMembership, EventTurnCompleted, "arguments_delta", "turn_started":
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
	case "", EventText, EventMessage, EventUser, EventThinking, EventNote, EventError:
		err = require("text")
		if header.Type == "" {
			event.Type = EventText
		}
		if header.Type == EventMessage {
			event.Role = "assistant"
		}
	case "arguments_delta":
		err = require("callId", "name", "text")
	case EventTurnMembership:
		err = require("turnId", "submissionIds")
	case EventTurnCompleted:
		err = require("turnId")
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
		err = require("name", "result")
		if len(event.Args) != 0 && string(event.Args) != "null" {
			args := event.Args
			if args[0] == '"' {
				var encoded string
				if decodeErr := json.Unmarshal(args, &encoded); decodeErr != nil {
					return nil, decodeErr
				}
				args = []byte(encoded)
			}
			// Invalid tool argument JSON is display-only, and has historically rendered empty.
			if json.Unmarshal(args, &event.ToolArgs) != nil {
				event.ToolArgs = map[string]any{}
			}
		}
	case EventUsage:
		var usage Usage
		if decodeErr := json.Unmarshal(data, &usage); decodeErr != nil {
			return nil, fmt.Errorf("invalid usage event: %w", decodeErr)
		}
		event.Usage = &usage
	case EventToolProgress:
		if fieldErr := validateToolProgress(fields["progress"]); fieldErr != nil {
			return nil, fieldErr
		}
		if _, exists := fields["progress"]; !exists {
			err = errors.New("invalid tool progress event: missing progress")
		}
		if progress := event.Progress; progress != nil {
			if len(progress.CallID) > 200 || len(progress.Name) > 100 || (progress.Phase != "generating" && progress.Phase != "running") {
				return nil, errors.New("invalid tool progress event")
			}
			progress.Name = cleanLabel(progress.Name)
			if intent := progress.Intent; intent != nil {
				if (intent.Kind != "write" && intent.Kind != "edit" && intent.Kind != "read" && intent.Kind != "run") || len(intent.Target) > 300 {
					progress.Intent = nil
				}
			}
			if code := progress.Code; code != nil {
				if code.Offset < 0 || (progress.Phase == "generating" && len(code.Text) > 512) || len(code.Text) > 16000 {
					progress.Code = nil
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
	if event.Timestamp != nil && *event.Timestamp < 0 {
		event.Timestamp = nil
	}
	if event.ElapsedMs < 0 {
		event.ElapsedMs = 0
	}
	if event.Image != nil {
		event.Image = ParseImageMetadata(event.Image)
	}
	if event.ToolTrace != nil {
		event.ToolTrace = ParseToolTrace(event.ToolTrace)
	}
	return &event, nil
}

// ResetStream discards unfinished tool arguments and starts the next stream from
// a fresh snapshot. Call it after the subscription has stopped writing.
func (c *ChatClient) ResetStream() {
	c.mu.Lock()
	c.argumentsByCall = make(map[string]*strings.Builder)
	c.afterSeq = -1
	c.mu.Unlock()
}

// Stream uses ctx for cancellation; onEvent must also honor ctx if it blocks.
func (c *ChatClient) Stream(ctx context.Context, tail int, onEvent func(StreamEvent) error) error {
	defer func() {
		// Cancellation also clears state when the request fails before reading.
		// Transient failures and EOF retain the cursor and unfinished arguments.
		if ctx.Err() != nil {
			c.ResetStream()
		}
	}()

	c.mu.Lock()
	afterSeq := c.afterSeq
	c.mu.Unlock()

	route := fmt.Sprintf("/stream?after_seq=%d", afterSeq)
	if tail > 0 {
		route += fmt.Sprintf("&tail=%d", tail)
	}

	operation := Operation{Name: "stream session", Method: http.MethodGet, Path: c.agentPath(route), Policy: ReadRecovery}
	return scanEventStream(ctx, c.conn, operation, streamLimits{lineBytes: 10 * 1024 * 1024, errorBytes: 64 * 1024}, func(scanner *bufio.Scanner) error {
		return c.readStream(ctx, scanner, onEvent)
	})
}

func (c *ChatClient) readStream(ctx context.Context, scanner *bufio.Scanner, onEvent func(StreamEvent) error) error {
	reporter := NewToolProgressReporter(func(progress *ToolProgress) error {
		return onEvent(StreamEvent{Type: EventToolProgress, Progress: progress})
	})
	defer func() { _ = reporter.Report(nil, "running") }()
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
				return fmt.Errorf("invalid stream error: %w", err)
			}
			if failure.Error != "" {
				return errors.New(failure.Error)
			}
			if failure.Text != "" {
				return errors.New(failure.Text)
			}
			return errors.New(payload)
		}
		var batch struct {
			Cursor *int              `json:"cursor"`
			Events []json.RawMessage `json:"events"`
		}
		if err := json.Unmarshal([]byte(payload), &batch); err != nil {
			return fmt.Errorf("invalid stream batch: %w", err)
		}
		if batch.Cursor == nil || *batch.Cursor < 0 || batch.Events == nil {
			return errors.New("invalid stream batch: missing cursor or events")
		}
		// Validate the whole batch before delivering events or changing preview state.
		events := make([]wireChatEvent, 0, len(batch.Events))
		for _, raw := range batch.Events {
			event, err := decodeChatEvent(raw)
			if err != nil {
				return err
			}
			if event != nil {
				events = append(events, *event)
			}
		}
		snapshot := false
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
			if event.Type == EventReset {
				snapshot = true
			}
			if event.Type == "turn_started" {
				continue
			}
			if event.Type == EventTool || (event.Type == EventToolProgress && event.Progress != nil && event.Progress.Phase == "running" && event.Progress.CallID != "") {
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
				if event.CallID != "" && event.Text != "" {
					arguments, err := c.appendArguments(event.CallID, event.Text)
					if err != nil {
						return err
					}
					call := &ToolCallAssembly{ID: event.CallID}
					call.Function.Name = event.ToolName
					call.Function.Arguments = arguments
					if err := reporter.Report(call, "generating"); err != nil {
						return err
					}
				}
				continue
			}
			event.Replayed = snapshot && event.Type != EventReset
			if err := onEvent(event.StreamEvent); err != nil {
				return err
			}
		}
		c.mu.Lock()
		c.afterSeq = *batch.Cursor
		c.mu.Unlock()
	}
	return nil
}

func (c *ChatClient) appendArguments(callID, text string) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	arguments, exists := c.argumentsByCall[callID]
	retained := 0
	for key, value := range c.argumentsByCall {
		retained += len(key) + value.Len()
	}
	extraCallID := 0
	if !exists {
		extraCallID = len(callID)
	}
	if (!exists && len(c.argumentsByCall) >= 32) || retained+len(text)+extraCallID > 2000000 {
		c.argumentsByCall = make(map[string]*strings.Builder)
		c.afterSeq = -1
		return "", errors.New("too many tool argument previews for this client to display")
	}
	if !exists {
		arguments = new(strings.Builder)
		c.argumentsByCall[callID] = arguments
	}
	arguments.WriteString(text)
	return arguments.String(), nil
}
