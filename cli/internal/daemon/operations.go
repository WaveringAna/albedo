package daemon

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"reflect"
	"time"
)

// OperationHandle freezes the chosen resource ID and exact admission payload.
// Retries always use this same input or session resource.
type OperationHandle struct {
	id        string
	operation operation
	kind      string
	sessionID string
}

func (handle *OperationHandle) ID() string       { return handle.id }
func (handle *OperationHandle) IsCreation() bool { return handle.kind == "creation" }

func operationID() (string, error) {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return "", fmt.Errorf("create resource ID: %w", err)
	}
	stamp := uint64(time.Now().UnixMilli())
	for i := 5; i >= 0; i-- {
		id[i] = byte(stamp)
		stamp >>= 8
	}
	id[6] = id[6]&0x0f | 0x70
	id[8] = id[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", id[:4], id[4:6], id[6:8], id[8:10], id[10:]), nil
}

func NewSubmission(session string, fields SubmissionRequest) (*OperationHandle, error) {
	id := fields.SubmissionID
	if id == "" {
		var err error
		id, err = operationID()
		if err != nil {
			return nil, err
		}
	}
	kind := fields.Type
	if kind == "" || kind == "user" {
		kind = "message"
	}
	var body any
	switch kind {
	case "message":
		if fields.Content == nil {
			return nil, errors.New("message input requires text")
		}
		var uploaded *wireImageUpload
		if fields.Image != nil {
			uploaded = &wireImageUpload{MimeType: string(fields.Image.MimeType), Data: fields.Image.Data}
		}
		body = struct {
			Kind     string           `json:"kind"`
			Text     string           `json:"text"`
			Image    *wireImageUpload `json:"image,omitempty"`
			ClientID string           `json:"client_id,omitempty"`
		}{kind, *fields.Content, uploaded, fields.ClientID}
	case "continue":
		body = struct {
			Kind     string `json:"kind"`
			ClientID string `json:"client_id,omitempty"`
		}{kind, fields.ClientID}
	case "skill":
		body = struct {
			Kind            string `json:"kind"`
			CandidateID     string `json:"candidate_id"`
			CatalogRevision string `json:"catalog_revision"`
			Arguments       string `json:"arguments"`
			ClientID        string `json:"client_id,omitempty"`
		}{kind, fields.Name, fields.CatalogRevision, fields.Arguments, fields.ClientID}
	case "command":
		body = struct {
			Kind      string          `json:"kind"`
			CommandID string          `json:"command_id"`
			Arguments json.RawMessage `json:"arguments"`
			ClientID  string          `json:"client_id,omitempty"`
		}{kind, fields.Name, fields.CommandArguments, fields.ClientID}
	default:
		return nil, fmt.Errorf("unknown input kind %q", kind)
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	handle := &OperationHandle{id: id, kind: kind, sessionID: session}
	handle.operation = operation{Name: "admit input", Method: http.MethodPut, Path: sessionPath(session, "/inputs/"+id), Body: json.RawMessage(payload), Policy: receiptRecovery, Handle: handle}
	return handle, nil
}

func NewCreation(fields CreateSessionRequest) (*OperationHandle, error) {
	kind := fields.Kind
	if kind == "" {
		kind = "new"
	}
	var body any
	switch kind {
	case "new":
		body = struct {
			Kind      string `json:"kind"`
			Workspace string `json:"workspace"`
			Name      string `json:"name,omitempty"`
			Provider  string `json:"provider_profile,omitempty"`
			Model     string `json:"model,omitempty"`
			Effort    string `json:"effort,omitempty"`
		}{kind, fields.Workspace, fields.Name, fields.Provider, fields.Model, fields.Effort}
	case "fork":
		body = struct {
			Kind       string `json:"kind"`
			Source     string `json:"source_session_id"`
			Checkpoint string `json:"checkpoint_id"`
			Name       string `json:"name,omitempty"`
		}{kind, fields.SourceSessionID, fields.CheckpointID, fields.Name}
	case "child":
		inputID, err := operationID()
		if err != nil {
			return nil, err
		}
		body = struct {
			Kind    string `json:"kind"`
			Parent  string `json:"parent_id"`
			Address string `json:"address"`
			Name    string `json:"name"`
			InputID string `json:"initial_input_id"`
			Task    string `json:"task"`
			Model   string `json:"model,omitempty"`
			Effort  string `json:"effort,omitempty"`
		}{kind, fields.ParentID, fields.Address, fields.Name, inputID, fields.Task, fields.Model, fields.Effort}
	default:
		return nil, fmt.Errorf("unknown creation kind %q", kind)
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	id, err := operationID()
	if err != nil {
		return nil, err
	}
	handle := &OperationHandle{id: id, kind: "creation", sessionID: id}
	handle.operation = operation{Name: "create session", Method: http.MethodPut, Path: sessionPath(id, ""), Body: json.RawMessage(payload), Headers: http.Header{"If-None-Match": {"*"}}, Policy: receiptRecovery, Handle: handle}
	return handle, nil
}

type OperationReceipt struct {
	OperationID     string
	Kind            string
	Status          string
	Target          string
	Result          json.RawMessage
	Error           json.RawMessage
	HTTPStatus      int
	DeliveryStatus  string
	BlockingReason  string
	TurnID          string
	AcceptanceOrder int64
}

func (receipt OperationReceipt) Rejection() error {
	if receipt.Status != "rejected" {
		return nil
	}
	return decodeAPIError(receipt.HTTPStatus, receipt.Error)
}

func GetInput(ctx context.Context, conn *Connection, session, id string) (OperationReceipt, error) {
	var input wireInput
	err := executeRead(ctx, conn, operation{Name: "read input", Method: http.MethodGet, Path: sessionPath(session, "/inputs/"+id), Policy: readRecovery}, func(data []byte) error {
		if err := decodeRequired(data, &input, "id", "session_id", "kind", "admission", "http_status", "problem", "accepted_at", "acceptance_order", "delivery", "blocking_reason", "transcript_position", "turn", "client_id"); err != nil {
			return err
		}
		if input.ID != id || input.SessionID != session {
			return fieldError("input identity")
		}
		return validInput(input)
	})
	if err != nil {
		return OperationReceipt{}, err
	}
	return inputReceipt(input), nil
}
func inputReceipt(input wireInput) OperationReceipt {
	body, _ := json.Marshal(input)
	problem, _ := json.Marshal(input.Problem)
	receipt := OperationReceipt{OperationID: input.ID, Kind: input.Kind, Status: input.Admission, Target: input.SessionID, Result: body, Error: problem, HTTPStatus: int(input.HTTPStatus), DeliveryStatus: value(input.Delivery)}
	receipt.AcceptanceOrder = value(input.AcceptanceOrder)
	if input.BlockingReason != nil {
		receipt.BlockingReason = input.BlockingReason.Detail
	}
	if input.Turn != nil {
		receipt.TurnID = input.Turn.ID
	}
	return receipt
}
func validInput(input wireInput) error {
	if input.ID == "" || input.SessionID == "" {
		return fieldError("input identity")
	}
	switch input.Kind {
	case "message", "continue", "skill", "command":
	default:
		return fieldError("input kind")
	}
	if input.Admission == "accepted" {
		if input.HTTPStatus != 202 || input.AcceptedAt == nil || input.AcceptanceOrder == nil || *input.AcceptanceOrder < 1 || input.Problem != nil {
			return fieldError("input admission")
		}
		switch value(input.Delivery) {
		case "pending", "committed", "cancelled":
			return nil
		}
	} else if input.Admission == "rejected" && input.HTTPStatus >= 400 && input.HTTPStatus <= 599 && input.Problem != nil && input.Delivery == nil && input.AcceptedAt == nil && input.AcceptanceOrder == nil && input.Turn == nil {
		return nil
	}
	return fieldError("input admission")
}
func ResolveOperation(ctx context.Context, conn *Connection, handle *OperationHandle) (OperationReceipt, error) {
	return GetInput(ctx, conn, handle.sessionID, handle.id)
}

func executeReceipt(ctx context.Context, conn *Connection, handle *OperationHandle, statuses []int, decode func([]byte, int) error) error {
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	for attempt := range 2 {
		err := executeMutation(ctx, conn, handle.operation, statuses, decode)
		if err == nil {
			return nil
		}
		var uncertain *UncertainOutcomeError
		collision := false
		if api, ok := errors.AsType[*APIError](err); ok {
			collision = handle.kind == "creation" && api.StatusCode == 412
		}
		if !errors.As(err, &uncertain) && !collision {
			return err
		}
		if ctx.Err() != nil {
			return uncertainOperation(handle.operation, err)
		}
		if handle.kind == "creation" {
			session, lookupErr := ResolveCreation(ctx, conn, handle)
			if lookupErr == nil {
				body, _ := json.Marshal(session.wire)
				return decode(body, statuses[0])
			}
			if IsOperationExpired(lookupErr) {
				return uncertainOperation(handle.operation, lookupErr)
			}
			if api, ok := errors.AsType[*APIError](lookupErr); ok {
				if api.Code == "creation_conflict" {
					return lookupErr
				}
				if len(api.Decision) > 0 && api.StatusCode >= 400 && api.StatusCode < 500 && api.StatusCode != 404 {
					return lookupErr
				}
			}
		} else {
			receipt, lookupErr := ResolveOperation(ctx, conn, handle)
			if lookupErr == nil {
				if receipt.Status == "rejected" {
					return receipt.Rejection()
				}
				if decodeErr := decode(receipt.Result, statuses[0]); decodeErr == nil {
					return nil
				}
			}
			if IsOperationExpired(lookupErr) {
				return uncertainOperation(handle.operation, lookupErr)
			}
		}
		if attempt == 1 {
			return uncertainOperation(handle.operation, err)
		}
	}
	panic("unreachable admission retry budget")
}
func ResolveCreation(ctx context.Context, conn *Connection, handle *OperationHandle) (Session, error) {
	session, err := GetSession(ctx, conn, handle.id)
	if err != nil {
		if api, ok := errors.AsType[*APIError](err); ok && len(api.Decision) > 0 {
			var decision wireCreationDecision
			if parseErr := decodeRequired(api.Decision, &decision, "kind", "session_id", "admission", "http_status", "creation", "decided_at", "deleted_at"); parseErr != nil {
				return Session{}, &ProtocolError{Code: "invalid_response", Operation: "read creation decision", Cause: parseErr}
			}
			if decision.Kind != "creation" || decision.SessionID != handle.ID() {
				return Session{}, fieldError("creation decision identity")
			}
			if decision.Creation != nil && !sameCreationIntent(handle.operation.Body.(json.RawMessage), decision.Creation.Submitted) {
				return Session{}, &APIError{StatusCode: 409, Code: "creation_conflict", Message: "the session ID belongs to another creation intent"}
			}
		}
		return Session{}, err
	}
	if session.wire.Creation == nil {
		return Session{}, fieldError("creation")
	}
	if !sameCreationIntent(handle.operation.Body.(json.RawMessage), session.wire.Creation.Submitted) {
		return Session{}, &APIError{StatusCode: 409, Code: "creation_conflict", Message: "the session ID belongs to another creation intent"}
	}

	return session, nil
}
func IsOperationExpired(err error) bool {
	api, ok := errors.AsType[*APIError](err)
	return ok && api.StatusCode == http.StatusGone
}

func sameCreationIntent(expected, stored json.RawMessage) bool {
	var left, right map[string]any
	if json.Unmarshal(expected, &left) != nil || json.Unmarshal(stored, &right) != nil {
		return false
	}
	var optional []string
	switch left["kind"] {
	case "new":
		optional = []string{"name", "provider_profile", "model", "effort"}
	case "fork":
		optional = []string{"name"}
	case "child":
		optional = []string{"model", "effort"}
	}
	for _, key := range optional {
		if _, ok := left[key]; !ok {
			left[key] = nil
		}
	}
	return reflect.DeepEqual(left, right)
}
