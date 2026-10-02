package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
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

type Member struct {
	Session string `json:"session"`
	Parent  string `json:"parent"`
	Name    string `json:"name"`
	Depth   int    `json:"depth"`
	Closed  bool   `json:"closed"`
}

type ChildResult struct {
	Session Session `json:"session"`
	Member  Member  `json:"member"`
}

type AgentNode struct {
	Parent  *string `json:"parent"`
	Address *string `json:"address"`
	Session Session `json:"session"`
	Name    string  `json:"name"`
	Depth   int     `json:"depth"`
	Running bool    `json:"running"`
	Closed  bool    `json:"closed"`
}

type AgentsSnapshot struct {
	Root  string      `json:"root"`
	Nodes []AgentNode `json:"nodes"`
}

type ChildRequest struct {
	Name string `json:"name"`
	Task string `json:"task"`
}

// StreamAgents delivers the first batch, including an empty readiness batch,
// then nonempty batches until the stream ends or onBatch fails.
// The caller controls cancellation, including any blocking work in onBatch.
func StreamAgents(ctx context.Context, conn *Connection, onBatch func([]AgentEvent) error) error {
	operation := operation{Name: "stream agents", Method: http.MethodGet, Path: "/agents/stream", Policy: readRecovery}
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

func CreateChild(ctx context.Context, conn *Connection, id string, body ChildRequest) (ChildResult, error) {
	var result ChildResult
	err := executeMutation(ctx, conn, operation{Name: "create child", Method: http.MethodPost, Path: sessionPath(id, "/children"), Body: body, Policy: authRecovery}, []int{201}, func(body []byte, _ int) error {
		var err error
		result, err = decodeChild(body)
		return err
	})
	return result, err
}

func GetAgents(ctx context.Context, conn *Connection, session string) (AgentsSnapshot, error) {
	var result AgentsSnapshot
	err := executeRead(ctx, conn, operation{Name: "get agents", Method: http.MethodGet, Path: "/agents?session=" + url.QueryEscape(session), Policy: readRecovery}, func(data []byte) error {
		fields, err := object(data)
		if err != nil {
			return err
		}
		if err = required(fields, "root", &result.Root); err != nil {
			return err
		}
		var rows []json.RawMessage
		if err = required(fields, "nodes", &rows); err != nil {
			return err
		}
		result.Nodes = make([]AgentNode, 0, len(rows))
		for _, row := range rows {
			fields, err := object(row)
			if err != nil {
				return err
			}
			var node AgentNode
			var sessionData json.RawMessage
			if err = nullable(fields, "parent", &node.Parent); err != nil {
				return err
			}
			if err = nullable(fields, "address", &node.Address); err != nil {
				return err
			}
			if err = required(fields, "session", &sessionData); err != nil {
				return err
			}
			node.Session, err = decodeSession(sessionData)
			if err != nil {
				return err
			}
			if err = required(fields, "name", &node.Name); err != nil {
				return err
			}
			if err = required(fields, "depth", &node.Depth); err != nil {
				return err
			}
			if node.Depth < 0 {
				return fieldError("depth")
			}
			if err = required(fields, "running", &node.Running); err != nil {
				return err
			}
			if err = required(fields, "closed", &node.Closed); err != nil {
				return err
			}
			result.Nodes = append(result.Nodes, node)
		}
		return nil
	})
	return result, err
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

func decodeChild(data []byte) (ChildResult, error) {
	fields, err := object(data)
	if err != nil {
		return ChildResult{}, err
	}
	var result ChildResult
	raw, ok := fields["session"]
	if !ok {
		return result, fieldError("session")
	}
	result.Session, err = decodeSession(raw)
	if err != nil {
		return ChildResult{}, err
	}
	member, err := object(fields["member"])
	if err != nil {
		return ChildResult{}, err
	}
	for _, field := range []struct {
		target any
		name   string
	}{{&result.Member.Session, "session"}, {&result.Member.Parent, "parent"}, {&result.Member.Name, "name"}, {&result.Member.Depth, "depth"}, {&result.Member.Closed, "closed"}} {
		if err := required(member, field.name, field.target); err != nil {
			return ChildResult{}, err
		}
	}
	return result, nil
}
