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
	Queued bool `json:"queued,omitempty"`
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

func (c *ChatClient) agentURL(path string) string {
	base := c.conn.BaseURL()
	return fmt.Sprintf("%s/sessions/%s%s", base, url.PathEscape(c.agentID), path)
}

func (c *ChatClient) submitPayload(ctx context.Context, payload map[string]any) (*SendResult, error) {
	reqCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()

	if c.clientID != "" {
		payload["clientId"] = c.clientID
	}

	req, err := newJSONRequest(reqCtx, http.MethodPost, c.agentURL("/events"), payload)
	if err != nil {
		return nil, err
	}

	body, err := requestBytes(c.conn, req, responseLimits{bodyBytes: 64 * 1024, errorBytes: 64 * 1024})
	if err != nil {
		return nil, err
	}

	var data struct {
		OK     bool `json:"ok"`
		Queued bool `json:"queued"`
	}
	_ = json.Unmarshal(body, &data)

	return &SendResult{
		OK:     true,
		Queued: data.Queued,
	}, nil
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

	req, err := newJSONRequest(reqCtx, http.MethodPost, c.agentURL("/interrupt"), map[string]any{})
	if err != nil {
		return false, err
	}

	body, err := requestBytes(c.conn, req, responseLimits{successStatus: http.StatusOK, bodyBytes: 64 * 1024, errorBytes: 64 * 1024})
	if err != nil {
		return false, err
	}

	var data struct {
		Interrupted bool `json:"interrupted"`
	}
	_ = json.Unmarshal(body, &data)
	return data.Interrupted, nil
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
	req, err := newJSONRequest(reqCtx, http.MethodGet, c.agentURL(route), nil)
	if err != nil {
		return nil, err
	}
	body, err := requestBytes(c.conn, req, responseLimits{successStatus: http.StatusOK, bodyBytes: 32 * 1024 * 1024, errorBytes: 64 * 1024})
	if err != nil {
		return nil, err
	}

	var data struct {
		Events []map[string]any `json:"events"`
		Before int64            `json:"before"`
		More   bool             `json:"more"`
	}
	if err := json.Unmarshal(body, &data); err != nil {
		return nil, err
	}
	page := &HistoryPage{Before: data.Before, More: data.More}
	for _, evMap := range data.Events {
		if ev := normalizeEvent(evMap); ev != nil {
			ev.Replayed = true
			page.Events = append(page.Events, *ev)
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
	req, err := newJSONRequest(reqCtx, http.MethodGet, c.agentURL("/context"), nil)
	if err != nil {
		return nil, err
	}
	body, err := requestBytes(c.conn, req, responseLimits{successStatus: http.StatusOK, bodyBytes: 1024 * 1024, errorBytes: 64 * 1024})
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

	req, err := newJSONRequest(reqCtx, http.MethodGet, c.agentURL("/status"), nil)
	if err != nil {
		return nil, err
	}

	body, err := requestBytes(c.conn, req, responseLimits{successStatus: http.StatusOK, bodyBytes: 64 * 1024, errorBytes: 64 * 1024})
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

func int64Field(raw map[string]any, key string) int64 {
	if n, ok := raw[key].(float64); ok && n > 0 {
		return int64(n)
	}
	return 0
}

// normalizeEvent parses one daemon event map, decoding a tool's JSON-encoded args.
func normalizeEvent(evMap map[string]any) *StreamEvent {
	if evMap["type"] == "tool" {
		if strArgs, ok := evMap["args"].(string); ok {
			var parsedArgs map[string]any
			if err := json.Unmarshal([]byte(strArgs), &parsedArgs); err == nil {
				evMap["args"] = parsedArgs
			} else {
				evMap["args"] = make(map[string]any)
			}
		}
	}
	return parseStreamEvent(evMap)
}

func parseStreamEvent(raw map[string]any) *StreamEvent {
	typ, _ := raw["type"].(string)
	if typ == "" {
		if txt, ok := raw["text"].(string); ok {
			return &StreamEvent{Type: EventText, Text: txt}
		}
		return nil
	}

	var timestamp *int64
	if ts, ok := raw["timestamp"].(float64); ok && ts >= 0 {
		t := int64(ts)
		timestamp = &t
	}

	switch typ {
	case "tool_progress":
		progVal := raw["progress"]
		if progVal == nil {
			return &StreamEvent{Type: EventToolProgress, Progress: nil}
		}
		progMap, ok := progVal.(map[string]any)
		if !ok {
			return nil
		}
		callID, _ := progMap["callId"].(string)
		name, _ := progMap["name"].(string)
		phase, _ := progMap["phase"].(string)
		if len(callID) > 200 || len(name) > 100 || (phase != "generating" && phase != "running") {
			return nil
		}

		var intent *ToolIntent
		if im, ok := progMap["intent"].(map[string]any); ok {
			k, _ := im["kind"].(string)
			t, _ := im["target"].(string)
			if (k == "write" || k == "edit" || k == "read" || k == "run") && len(t) <= 300 {
				intent = &ToolIntent{Kind: k, Target: t}
			}
		}

		var code *ToolCodePreview
		if cm, ok := progMap["code"].(map[string]any); ok {
			off, hasOff := cm["offset"].(float64)
			txt, hasTxt := cm["text"].(string)
			if hasOff && hasTxt && off >= 0 {
				switch {
				case phase == "generating" && len(txt) <= 512:
					code = &ToolCodePreview{Offset: int(off), Text: txt}
				case phase == "running" && len(txt) <= 16000:
					// a running call's code is its start: what it does, and
					// the first line to name it by
					if intent == nil && name == "python" {
						intent = ParsePythonIntent(txt)
					}
					head, _, _ := strings.Cut(strings.TrimSpace(txt), "\n")
					code = &ToolCodePreview{Text: sanitizeControlRunes(head)}
				}
			}
		}

		return &StreamEvent{
			Type: EventToolProgress,
			Progress: &ToolProgress{
				CallID: callID,
				Name:   cleanLabel(name),
				Phase:  phase,
				Intent: intent,
				Code:   code,
			},
		}

	case "message":
		txt, _ := raw["text"].(string)
		return &StreamEvent{
			Type:      EventMessage,
			Role:      "assistant",
			Text:      txt,
			Timestamp: timestamp,
		}

	case "interrupted":
		return &StreamEvent{Type: EventInterrupted}

	case "retry":
		return &StreamEvent{Type: EventRetry}

	case "reset":
		return &StreamEvent{Type: EventReset, Before: int64Field(raw, "before"), More: raw["more"] == true}

	case "committed":
		seq := int64Field(raw, "seq")
		if seq <= 0 {
			return nil
		}
		return &StreamEvent{Type: EventCommitted, Seq: seq}

	case "note":
		txt, _ := raw["text"].(string)
		return &StreamEvent{Type: EventNote, Text: txt}

	case "user":
		txt, _ := raw["text"].(string)
		source, _ := raw["source"].(string)
		trig, _ := raw["triggeredAt"].(string)
		clientID, _ := raw["clientId"].(string)
		img := ParseImageMetadata(raw["image"])
		return &StreamEvent{
			Type:        EventUser,
			Text:        txt,
			Source:      source,
			TriggeredAt: trig,
			ClientID:    clientID,
			Timestamp:   timestamp,
			Image:       img,
		}

	case "thinking":
		txt, _ := raw["text"].(string)
		return &StreamEvent{Type: EventThinking, Text: txt, ElapsedMs: int64Field(raw, "elapsedMs")}

	case "error":
		txt, _ := raw["text"].(string)
		return &StreamEvent{Type: EventError, Text: txt}

	case "tool":
		name, _ := raw["name"].(string)
		result, _ := raw["result"].(string)
		args, _ := raw["args"].(map[string]any)
		trace := ParseToolTrace(raw["trace"])
		return &StreamEvent{
			Type:       EventTool,
			ToolName:   name,
			ToolArgs:   args,
			ToolResult: result,
			ToolTrace:  trace,
		}

	case "usage":
		model, _ := raw["model"].(string)
		var cacheFade []CacheStep
		if data, err := json.Marshal(raw["cacheFade"]); err == nil {
			if err := json.Unmarshal(data, &cacheFade); err != nil {
				cacheFade = nil
			}
		}
		var recordedAt *int64
		if ra, ok := raw["recordedAt"].(float64); ok {
			r := int64(ra)
			recordedAt = &r
		}
		getInt := func(k string) *int {
			if v, ok := raw[k].(float64); ok {
				i := int(v)
				return &i
			}
			return nil
		}
		getFloat := func(k string) *float64 {
			if v, ok := raw[k].(float64); ok {
				return &v
			}
			return nil
		}
		return &StreamEvent{
			Type: EventUsage,
			Usage: &Usage{
				Model:              model,
				RecordedAt:         recordedAt,
				PromptTokens:       getInt("promptTokens"),
				CachedPromptTokens: getInt("cachedPromptTokens"),
				CacheWriteTokens:   getInt("cacheWriteTokens"),
				CompletionTokens:   getInt("completionTokens"),
				TotalTokens:        getInt("totalTokens"),
				ElapsedMs:          getFloat("elapsedMs"),
				TokensPerSecond:    getFloat("tokensPerSecond"),
				CacheFade:          cacheFade,
			},
		}

	case "compacted":
		evicted, hasEv := raw["evicted"].(float64)
		summary, hasSum := raw["summary"].(string)
		if hasEv && hasSum && evicted >= 0 && evicted <= 1000000 && len(summary) <= 60000 {
			strategy, _ := raw["strategy"].(string)
			return &StreamEvent{
				Type:     EventCompacted,
				Evicted:  int(evicted),
				Summary:  summary,
				Strategy: strategy,
			}
		}
		return nil

	default:
		if txt, ok := raw["text"].(string); ok {
			return &StreamEvent{Type: EventText, Text: txt}
		}
		return nil
	}
}

// Stream uses ctx for cancellation; onEvent must also honor ctx if it blocks.
func (c *ChatClient) Stream(ctx context.Context, tail int, onEvent func(StreamEvent) error) error {
	c.mu.Lock()
	afterSeq := c.afterSeq
	c.mu.Unlock()

	route := fmt.Sprintf("/stream?after_seq=%d", afterSeq)
	if tail > 0 {
		route += fmt.Sprintf("&tail=%d", tail)
	}

	req, err := newJSONRequest(ctx, http.MethodGet, c.agentURL(route), nil)
	if err != nil {
		return err
	}
	return scanEventStream(c.conn, req, streamLimits{lineBytes: 10 * 1024 * 1024, errorBytes: 64 * 1024}, func(scanner *bufio.Scanner) error {
		return c.readStream(ctx, scanner, onEvent)
	})
}

func (c *ChatClient) readStream(ctx context.Context, scanner *bufio.Scanner, onEvent func(StreamEvent) error) error {
	reporter := NewToolProgressReporter(func(prog *ToolProgress) error {
		return onEvent(StreamEvent{Type: EventToolProgress, Progress: prog})
	})

	defer func() {
		_ = reporter.Report(nil, "running")
		if ctx.Err() != nil {
			// Cancellation starts the next subscription from a fresh snapshot.
			// Transient stream failures retain the cursor and partial tool previews.
			c.mu.Lock()
			c.afterSeq = -1
			c.argumentsByCall = make(map[string]*strings.Builder)
			c.mu.Unlock()
		}
	}()

	var eventType string

	for scanner.Scan() {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
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

		var raw any
		if err := json.Unmarshal([]byte(payload), &raw); err != nil {
			continue
		}

		if eventType == "error" {
			errStr := payload
			if m, ok := raw.(map[string]any); ok {
				if e, ok := m["error"].(string); ok {
					errStr = e
				} else if t, ok := m["text"].(string); ok {
					errStr = t
				}
			}
			return errors.New(errStr)
		}

		rawMap, isMap := raw.(map[string]any)
		if isMap {
			if cursorVal, hasCursor := rawMap["cursor"]; hasCursor {
				if cursorNum, ok := cursorVal.(float64); ok {
					if eventsArr, ok := rawMap["events"].([]any); ok {
						// a reset opens the snapshot, and the snapshot is the rest of its page
						snapshot := false
						for _, evRaw := range eventsArr {
							evMap, ok := evRaw.(map[string]any)
							if !ok {
								continue
							}
							itemType, _ := evMap["type"].(string)
							switch itemType {
							case "reset", "retry", "turn_started", "message", "interrupted", "error":
								c.mu.Lock()
								c.argumentsByCall = make(map[string]*strings.Builder)
								c.mu.Unlock()
								if err := reporter.Report(nil, "running"); err != nil {
									return err
								}
							}

							if itemType == "reset" {
								snapshot = true
								if err := onEvent(*parseStreamEvent(evMap)); err != nil {
									return err
								}
								continue
							}
							if itemType == "turn_started" {
								continue
							}
							if itemType == "tool" {
								if callID, ok := evMap["callId"].(string); ok {
									c.mu.Lock()
									delete(c.argumentsByCall, callID)
									c.mu.Unlock()
								}
								if err := reporter.Report(nil, "running"); err != nil {
									return err
								}
							}
							if itemType == "tool_progress" {
								if prog, ok := evMap["progress"].(map[string]any); ok {
									ph, _ := prog["phase"].(string)
									cid, _ := prog["callId"].(string)
									if ph == "running" && cid != "" {
										c.mu.Lock()
										delete(c.argumentsByCall, cid)
										c.mu.Unlock()
										if err := reporter.Report(nil, "running"); err != nil {
											return err
										}
									}
								}
							}
							if itemType == "arguments_delta" {
								callID, _ := evMap["callId"].(string)
								name, _ := evMap["name"].(string)
								text, _ := evMap["text"].(string)
								if callID != "" && text != "" {
									c.mu.Lock()
									arguments, exists := c.argumentsByCall[callID]
									fresh := !exists

									retained := 0
									for k, v := range c.argumentsByCall {
										retained += len(k) + v.Len()
									}

									extraCallID := 0
									if fresh {
										extraCallID = len(callID)
									}

									if (fresh && len(c.argumentsByCall) >= 32) || retained+len(text)+extraCallID > 2000000 {
										c.argumentsByCall = make(map[string]*strings.Builder)
										c.afterSeq = -1
										c.mu.Unlock()
										return errors.New("too many tool argument previews for this client to display")
									}

									if fresh {
										arguments = new(strings.Builder)
										c.argumentsByCall[callID] = arguments
									}
									// Append-only builders keep earlier String snapshots immutable.
									arguments.WriteString(text)
									args := arguments.String()
									c.mu.Unlock()

									call := &ToolCallAssembly{
										ID: callID,
									}
									call.Function.Name = name
									call.Function.Arguments = args
									if err := reporter.Report(call, "generating"); err != nil {
										return err
									}
									continue
								}
							}

							if ev := normalizeEvent(evMap); ev != nil {
								ev.Replayed = snapshot
								if err := onEvent(*ev); err != nil {
									return err
								}
							}
						}

						c.mu.Lock()
						c.afterSeq = int(cursorNum)
						c.mu.Unlock()
						continue
					}
				}
			}
		}
	}

	return nil
}
