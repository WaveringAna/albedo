package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"unicode/utf8"

	"albedo/cli/internal/daemon/protocol"
)

type Activity = protocol.Activity
type Cursor = protocol.Cursor

func validGeneration(generation string) bool {
	if len(generation) != 22 {
		return false
	}
	for i := range len(generation) {
		c := generation[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

type AgentEvent struct {
	MailID                                                                                                     string
	Progress                                                                                                   *ToolProgress
	Type, Session, Parent, Name, Model, From, To, FromName, Kind, Text, CallID, ProgressCallID, Output, Source string
	Depth, Bytes                                                                                               int
	Running                                                                                                    bool
	Cursor                                                                                                     *Cursor
	Status                                                                                                     *AgentStatus
	CurrentProgress                                                                                            []ToolProgress
	Activity                                                                                                   *Activity
	SessionIDs                                                                                                 []string
	ScopeDirty                                                                                                 bool
}
type AgentNode struct {
	Parent, Address *string
	Session         Session
	Name            string
	Depth           int
	Running, Closed bool
	Cursor          *Cursor
	Activity        Activity
	CurrentProgress []ToolProgress
}
type AgentsSnapshot struct {
	Root, FamilyRevision string
	Nodes                []AgentNode
}

func StreamAgents(ctx context.Context, conn *Connection, onBatch func([]AgentEvent) error) error {
	first := true
	err := scanEventStream(ctx, conn, operation{Name: "watch sessions", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewListSessionsRequest(base, nil)
	}, Policy: readRecovery}, streamLimits{requireSSE: true, lineBytes: 1048577}, func(scanner *bufio.Scanner) error {
		return scanSSEFrames(ctx, scanner, func(payload []byte) error {
			var w struct {
				Events []json.RawMessage `json:"events"`
			}
			if err := decodeRequired(payload, &w, "events"); err != nil {
				return streamFailure(StreamProtocol, err)
			}
			if w.Events == nil || len(w.Events) > 256 {
				return streamFailure(StreamProtocol, fieldError("collection batch"))
			}
			events := []AgentEvent{}
			types := []string{}
			for _, raw := range w.Events {
				event, err := decodeAgentEvent(raw)
				if err != nil {
					return streamFailure(StreamProtocol, err)
				}
				var kind struct {
					Type string `json:"type"`
				}
				_ = json.Unmarshal(raw, &kind)
				types = append(types, kind.Type)
				if event != nil {
					events = append(events, *event)
				}
			}
			if first {
				if len(types) != 2 || types[0] != "ready" || types[1] != "reset" {
					return streamFailure(StreamProtocol, errors.New("collection stream requires ready and reset before snapshots"))
				}
				first = false
			} else {
				for _, kind := range types {
					if kind == "ready" || kind == "reset" {
						return streamFailure(StreamProtocol, fieldError("collection readiness"))
					}
					if kind == "overflow" || kind == "failure" {
						if len(types) != 1 {
							return streamFailure(StreamProtocol, fieldError("terminal collection batch"))
						}
					}
				}
			}
			if err := onBatch(events); err != nil {
				return streamFailure(StreamTerminal, err)
			}
			if len(types) == 1 && types[0] == "overflow" {
				return streamFailure(StreamTransient, errors.New("collection stream overflow; capture a fresh snapshot"))
			}
			return nil
		})
	})
	return classifyStreamFailure(err)
}
func decodeAgentEvent(raw json.RawMessage) (*AgentEvent, error) {
	var envelope struct {
		Type string          `json:"type"`
		Data json.RawMessage `json:"data"`
	}
	if err := decodeRequired(raw, &envelope, "type", "data"); err != nil {
		return nil, err
	}
	if envelope.Type == "" || envelope.Data == nil || string(envelope.Data) == "null" {
		return nil, fieldError("collection event")
	}
	event := &AgentEvent{Type: envelope.Type}
	switch envelope.Type {
	case "ready", "overflow":
	case "reset":
		var d struct {
			Reason string `json:"reason"`
		}
		if err := decodeRequired(envelope.Data, &d, "reason"); err != nil {
			return nil, err
		}
		if d.Reason != "initial" {
			return nil, fieldError("collection reset")
		}
	case "activity":
		var d struct {
			SessionID string                  `json:"session_id"`
			Cursor    Cursor                  `json:"cursor"`
			Status    protocol.SessionStatus  `json:"status"`
			Progress  []protocol.ToolProgress `json:"current_progress"`
			Activity  Activity                `json:"activity"`
		}
		if err := decodeRequired(envelope.Data, &d, "session_id", "cursor", "status", "current_progress", "activity"); err != nil {
			return nil, err
		}
		if d.SessionID == "" || !validGeneration(d.Cursor.Generation) || d.Cursor.Sequence < 0 || len(d.Progress) > 32 {
			return nil, fieldError("collection activity")
		}
		if err := validateSessionStatus(d.Status); err != nil {
			return nil, err
		}
		if err := validateActivity(d.Activity); err != nil {
			return nil, err
		}
		event.Session = d.SessionID
		event.Cursor = &d.Cursor
		status := statusValue(d.Status, protocol.Kernel{})
		event.Status = &status
		event.Running = status.Running
		event.Activity = &d.Activity
		event.CurrentProgress = []ToolProgress{}
		seen := map[string]bool{}
		for _, p := range d.Progress {
			if seen[p.CallID] {
				return nil, fieldError("duplicate collection progress")
			}
			seen[p.CallID] = true
			data, _ := json.Marshal(p)
			progress, err := decodeToolProgress(data)
			if err != nil || progress == nil {
				return nil, fieldError("collection progress")
			}
			event.CurrentProgress = append(event.CurrentProgress, *progress)
		}
	case "mail":
		var d protocol.MailMetadata
		if err := decodeRequired(envelope.Data, &d); err != nil {
			return nil, err
		}
		event.MailID = d.MailID
		event.From, event.To, event.FromName, event.Kind, event.Bytes = value(d.SenderSessionID), d.ReceiverSessionID, value(d.SenderLabel), d.Kind, int(d.Bytes)
	case "invalidate":
		var d struct {
			SessionIDs []string `json:"session_ids"`
			ScopeDirty bool     `json:"scope_dirty"`
		}
		if err := decodeRequired(envelope.Data, &d, "urls", "session_ids", "scope_dirty"); err != nil {
			return nil, err
		}
		event.SessionIDs, event.ScopeDirty = d.SessionIDs, d.ScopeDirty
	case "failure":
		var d protocol.SafeReason
		if err := decodeRequired(envelope.Data, &d); err != nil {
			return nil, err
		}
		return nil, streamFailure(StreamTerminal, &APIError{Code: d.Code, Message: d.Detail})
	default:
		return nil, nil
	}
	return event, nil
}
func GetAgents(ctx context.Context, conn *Connection, id string) (AgentsSnapshot, error) {
	selected, err := GetSession(ctx, conn, id)
	if err != nil {
		return AgentsSnapshot{}, err
	}
	params := protocol.ListSessionsParams{Scope: new("all"), FamilyID: &selected.RootID, Limit: new(int64(200))}
	result := AgentsSnapshot{Root: selected.RootID, Nodes: []AgentNode{}}
	seen := map[string]bool{}
	for {
		var page protocol.SessionPage
		err := executeRead(ctx, conn, operation{Name: "read session family", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
			return protocol.NewListSessionsRequest(base, &params)
		}, Policy: readRecovery}, func(data []byte) error { return decodeRequired(data, &page, "family") })
		if err != nil {
			return result, err
		}
		if result.FamilyRevision != "" && page.Family.Revision != result.FamilyRevision {
			return result, &APIError{StatusCode: 409, Code: "family_changed", Message: "family changed while paging; refresh it"}
		}
		result.FamilyRevision = page.Family.Revision
		for _, row := range page.Items {
			session := summaryValue(row)
			session.FamilyRevision = result.FamilyRevision
			node := AgentNode{Parent: row.ParentID, Address: row.Address, Session: session, Name: session.Title, Depth: session.Depth, Running: session.Status.Running, Closed: session.Closed, Cursor: row.Cursor, Activity: row.Activity, CurrentProgress: []ToolProgress{}}
			for _, p := range row.CurrentProgress {
				data, _ := json.Marshal(p)
				progress, err := decodeToolProgress(data)
				if err != nil || progress == nil {
					return result, fieldError("family progress")
				}
				node.CurrentProgress = append(node.CurrentProgress, *progress)
			}
			result.Nodes = append(result.Nodes, node)
		}
		if page.Next == nil {
			return result, nil
		}
		if seen[*page.Next] {
			return result, fieldError("family cursor")
		}
		seen[*page.Next] = true
		params.Next = page.Next
	}
}

func validateActivity(activity Activity) error {
	if activity.CurrentRequest != nil && (activity.CurrentRequest.InputID == "" || len([]rune(activity.CurrentRequest.Text)) > 512) {
		return fieldError("activity request")
	}
	if activity.LatestProgress != nil && len([]rune(*activity.LatestProgress)) > 512 {
		return fieldError("activity progress")
	}
	if len(activity.Lines) > 12 || activity.Lines == nil || activity.OutputScalars < 0 || activity.OutputUTF8Bytes < 0 || timestampMilliseconds(activity.ObservedAt) == nil {
		return fieldError("activity")
	}
	for _, line := range activity.Lines {
		if len(line.Text) > 1024 || utf8.RuneCountInString(line.Text) > 256 {
			return fieldError("activity line")
		}
		switch line.Kind {
		case "assistant", "thinking", "tool", "input", "note", "error":
		default:
			return fieldError("activity kind")
		}
	}
	return nil
}
