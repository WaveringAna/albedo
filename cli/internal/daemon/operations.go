package daemon

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"time"
)

// OperationHandle retains one intent and its exact encoded request through uncertainty.
// Reusing this handle never creates a new operation ID.
type OperationHandle struct {
	id        string
	operation operation
	kind      string
}

func (handle *OperationHandle) ID() string { return handle.id }

func operationID() (string, error) {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return "", fmt.Errorf("create operation ID: %w", err)
	}
	timestamp := uint64(time.Now().UnixMilli())
	for i := 5; i >= 0; i-- {
		id[i] = byte(timestamp)
		timestamp >>= 8
	}
	id[6] = id[6]&0x0f | 0x70
	id[8] = id[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", id[0:4], id[4:6], id[6:8], id[8:10], id[10:16]), nil
}

func NewSubmission(session string, fields SubmissionRequest) (*OperationHandle, error) {
	id, err := operationID()
	if err != nil {
		return nil, err
	}
	if fields.SubmissionID == "" {
		fields.SubmissionID = id
	}
	payload, err := json.Marshal(struct {
		SubmissionRequest
		OperationID string `json:"operationId"`
	}{fields, id})
	if err != nil {
		return nil, err
	}
	handle := &OperationHandle{id: id, kind: fields.Type}
	handle.operation = operation{
		Name:   "submit message",
		Method: http.MethodPost,
		Path:   sessionPath(session, "/events"),
		Body:   json.RawMessage(payload),
		Policy: receiptRecovery,
		Handle: handle,
	}
	return handle, nil
}
func NewCreation(fields CreateSessionRequest) (*OperationHandle, error) {
	id, err := operationID()
	if err != nil {
		return nil, err
	}
	payload, err := json.Marshal(struct {
		CreateSessionRequest
		OperationID string `json:"operationId"`
	}{fields, id})
	if err != nil {
		return nil, err
	}
	handle := &OperationHandle{id: id}
	handle.operation = operation{
		Name:   "create session",
		Method: http.MethodPost,
		Path:   "/sessions",
		Body:   json.RawMessage(payload),
		Policy: receiptRecovery,
		Handle: handle,
	}
	return handle, nil
}

type OperationReceipt struct {
	OperationID    string          `json:"operationId"`
	Kind           string          `json:"kind"`
	Status         string          `json:"status"`
	Target         string          `json:"target"`
	Result         json.RawMessage `json:"result"`
	Error          json.RawMessage `json:"error"`
	HTTPStatus     int             `json:"httpStatus"`
	DeliveryStatus string          `json:"deliveryStatus"`
	BlockingReason string          `json:"blockingReason"`
}

func (receipt OperationReceipt) Rejection() error {
	if receipt.Status != "rejected" {
		return nil
	}
	return decodeAPIError(receipt.HTTPStatus, receipt.Error)
}

func GetOperation(ctx context.Context, conn *Connection, id string) (OperationReceipt, error) {
	var receipt OperationReceipt
	err := executeRead(ctx, conn, operation{Name: "query operation", Method: http.MethodGet, Path: "/operations/" + url.PathEscape(id), Policy: readRecovery}, func(data []byte) error {
		var wire struct {
			OperationID    *string         `json:"operationId"`
			Kind           *string         `json:"kind"`
			Target         *string         `json:"target"`
			Status         *string         `json:"status"`
			HTTPStatus     *int            `json:"httpStatus"`
			Result         json.RawMessage `json:"result"`
			Error          json.RawMessage `json:"error"`
			DeliveryStatus json.RawMessage `json:"deliveryStatus"`
			BlockingReason json.RawMessage `json:"blockingReason"`
		}
		if err := json.Unmarshal(data, &wire); err != nil {
			return err
		}
		if wire.OperationID == nil || wire.Kind == nil || wire.Target == nil || wire.Status == nil || wire.HTTPStatus == nil {
			return errors.New("incomplete operation receipt")
		}
		receipt = OperationReceipt{OperationID: *wire.OperationID, Kind: *wire.Kind, Target: *wire.Target, Status: *wire.Status, HTTPStatus: *wire.HTTPStatus}
		if receipt.OperationID != id || (receipt.Status != "accepted" && receipt.Status != "rejected") || receipt.Kind == "" || receipt.HTTPStatus < 100 || receipt.HTTPStatus > 599 {
			return errors.New("invalid operation receipt")
		}
		// A rejected creation has no allocated session to name as its target.
		if receipt.Target == "" && !(receipt.Kind == "create" && receipt.Status == "rejected") {
			return fieldError("target")
		}
		if receipt.Status == "accepted" {
			if wire.Result == nil || string(wire.Result) == "null" {
				return fieldError("result")
			}
			receipt.Result = wire.Result
		} else {
			if wire.Error == nil || string(wire.Error) == "null" {
				return fieldError("error")
			}
			receipt.Error = wire.Error
		}
		if wire.DeliveryStatus == nil {
			return fieldError("deliveryStatus")
		}
		if wire.BlockingReason == nil {
			return fieldError("blockingReason")
		}
		var delivery, reason *string
		if err := json.Unmarshal(wire.DeliveryStatus, &delivery); err != nil {
			return err
		}
		if err := json.Unmarshal(wire.BlockingReason, &reason); err != nil {
			return err
		}
		if delivery != nil {
			receipt.DeliveryStatus = *delivery
		}
		if reason != nil {
			receipt.BlockingReason = *reason
		}
		return nil
	})
	return receipt, err
}

// ResolveOperation only reads the original receipt; it never submits another request.
func ResolveOperation(ctx context.Context, conn *Connection, handle *OperationHandle) (OperationReceipt, error) {
	return GetOperation(ctx, conn, handle.ID())
}

func executeReceipt(ctx context.Context, conn *Connection, handle *OperationHandle, statuses []int, decode func([]byte, int) error) error {
	if ctx == nil {
		ctx = context.Background()
	}
	reqCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	for attempt := range 2 {
		err := executeMutation(reqCtx, conn, handle.operation, statuses, decode)
		if err == nil {
			return nil
		}
		if _, uncertain := errors.AsType[*UncertainOutcomeError](err); !uncertain {
			if reqCtx.Err() != nil {
				return uncertainOperation(handle.operation, err)
			}
			return err
		}
		if reqCtx.Err() != nil {
			return err
		}
		receipt, lookupErr := GetOperation(reqCtx, conn, handle.ID())
		if IsOperationExpired(lookupErr) {
			return uncertainOperation(handle.operation, lookupErr)
		}
		if lookupErr == nil {
			if receipt.Status == "rejected" {
				return receipt.Rejection()
			}
			if decodeErr := decode(receipt.Result, statuses[0]); decodeErr == nil {
				return nil
			}
		}
		if attempt == 1 || reqCtx.Err() != nil {
			return errors.Join(err, reqCtx.Err())
		}
	}
	panic("unreachable operation retry budget")
}

func ResolveCreation(ctx context.Context, conn *Connection, handle *OperationHandle) (Session, error) {
	receipt, err := ResolveOperation(ctx, conn, handle)
	if err != nil {
		if api, ok := errors.AsType[*APIError](err); ok && api.StatusCode == http.StatusGone {
			return Session{}, err
		}
		return Session{}, uncertainOperation(handle.operation, err)
	}
	if receipt.Status == "rejected" {
		return Session{}, decodeAPIError(receipt.HTTPStatus, receipt.Error)
	}
	fields, decodeErr := object(receipt.Result)
	if decodeErr != nil {
		return Session{}, uncertainOperation(handle.operation, decodeErr)
	}
	var id string
	if decodeErr = required(fields, "operationId", &id); decodeErr != nil || id != handle.ID() {
		return Session{}, invalidResponse(handle.operation, "operationId", fieldError("operationId"))
	}
	session, decodeErr := decodeSession(receipt.Result)
	if decodeErr != nil {
		return Session{}, invalidResponse(handle.operation, "session", decodeErr)
	}
	return session, nil
}

func (handle *OperationHandle) IsContinuation() bool { return handle.kind == "continue" }

// IsOperationExpired identifies a receipt whose admission outcome can no longer be recovered.
func IsOperationExpired(err error) bool {
	api, ok := errors.AsType[*APIError](err)
	return ok && api.StatusCode == http.StatusGone && api.Code == "operation_expired"
}
