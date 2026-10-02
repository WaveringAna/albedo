package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
)

// AgentEvent is one event from the daemon's agent bus.
type AgentEvent struct {
	Progress *ToolProgress `json:"progress"`
	Type     string        `json:"type"`
	Session  string        `json:"session"`
	Parent   string        `json:"parent"`
	Name     string        `json:"name"`
	Model    string        `json:"model"`
	From     string        `json:"from"`
	To       string        `json:"to"`
	FromName string        `json:"fromName"`
	Kind     string        `json:"kind"`
	Text     string        `json:"text"`
	CallID   string        `json:"callId"`
	Output   string        `json:"output"`
	Source   string        `json:"source"`
	Depth    int           `json:"depth"`
	Bytes    int           `json:"bytes"`
	Running  bool          `json:"running"`
}

func decodeAgentEvent(raw json.RawMessage) (*AgentEvent, error) {
	var header struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(raw, &header); err != nil {
		return nil, fmt.Errorf("invalid agent event: %w", err)
	}
	if header.Type == "" {
		return nil, errors.New("invalid agent event: missing type")
	}
	switch header.Type {
	case "overflow":
		return &AgentEvent{Type: "overflow"}, nil
	case "spawn", "gone", "mail", "running", "text", "thinking", "arguments_delta", "tool_progress", "tool", "user", "message", "error", "interrupted", "progress", "renamed", "closed":
	default:
		return nil, nil
	}
	var event AgentEvent
	if err := json.Unmarshal(raw, &event); err != nil {
		return nil, fmt.Errorf("invalid %s agent event: %w", header.Type, err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return nil, err
	}
	required := []string{"session"}
	switch event.Type {
	case "mail":
		required = []string{"to", "bytes", "kind"}
	case "spawn":
		required = append(required, "parent", "name", "model", "depth")
	case "running":
		required = append(required, "running")
	case "text", "thinking", "arguments_delta", "user", "message", "error", "progress":
		required = append(required, "text")
		if event.Type == "arguments_delta" {
			required = append(required, "callId", "name")
		}
	case "tool_progress":
		if err := validateToolProgress(fields["progress"]); err != nil {
			return nil, err
		}
		required = append(required, "progress")
	case "tool":
		required = append(required, "output")
	case "renamed":
		required = append(required, "name")
	}
	for _, name := range required {
		if value, exists := fields[name]; !exists || (string(value) == "null" && name != "progress") {
			return nil, fmt.Errorf("invalid %s agent event: missing %s", event.Type, name)
		}
	}
	return &event, nil
}

// StreamAgents delivers the first batch, including an empty readiness batch,
// then nonempty batches until the stream ends or onBatch fails.
// The caller controls cancellation, including any blocking work in onBatch.
func StreamAgents(ctx context.Context, conn *Connection, onBatch func([]AgentEvent) error) error {
	operation := Operation{Name: "stream agents", Method: http.MethodGet, Path: "/agents/stream", Policy: ReadRecovery}
	first := true
	err := scanEventStream(ctx, conn, operation, streamLimits{requireSSE: true, lineBytes: 8 * 1024 * 1024}, func(scanner *bufio.Scanner) error {
		for scanner.Scan() {
			line := scanner.Text()
			if !strings.HasPrefix(line, "data:") {
				continue
			}
			var batch struct {
				Events []json.RawMessage `json:"events"`
			}
			if err := json.Unmarshal([]byte(strings.TrimSpace(line[5:])), &batch); err != nil {
				return streamFailure(StreamProtocol, fmt.Errorf("invalid agent batch: %w", err))
			}
			if batch.Events == nil {
				return streamFailure(StreamProtocol, errors.New("invalid agent batch: missing events"))
			}
			events := make([]AgentEvent, 0, len(batch.Events))
			for _, raw := range batch.Events {
				event, err := decodeAgentEvent(raw)
				if err != nil {
					return streamFailure(StreamProtocol, err)
				}
				if event != nil {
					if event.Type == "overflow" && len(batch.Events) != 1 {
						return streamFailure(StreamProtocol, errors.New("overflow must be the sole agent event"))
					}
					events = append(events, *event)
				}
			}
			if len(events) == 0 && !first {
				continue
			}
			first = false
			if err := onBatch(events); err != nil {
				return streamFailure(StreamTerminal, err)
			}
			if len(events) == 1 && events[0].Type == "overflow" {
				return nil
			}
		}
		return nil
	})
	return classifyStreamFailure(err)
}
