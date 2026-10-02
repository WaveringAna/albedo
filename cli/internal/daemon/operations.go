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
	ID        string
	operation Operation
	kind      string
}

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

func newIntent(name, path string, fields map[string]any) (*OperationHandle, error) {
	id, err := operationID()
	if err != nil {
		return nil, err
	}
	request := make(map[string]any, len(fields)+1)
	for key, value := range fields {
		request[key] = value
	}
	request["operationId"] = id
	if name == "submit message" {
		if _, supplied := request["submissionId"]; !supplied {
			request["submissionId"] = id
		}
	}
	payload, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}
	kind, _ := fields["type"].(string)
	handle := &OperationHandle{ID: id, kind: kind}
	handle.operation = Operation{Name: name, Method: http.MethodPost, Path: path, Body: json.RawMessage(payload), Policy: ReceiptRecovery, Handle: handle}
	return handle, nil
}
func NewSubmission(session string, fields map[string]any) (*OperationHandle, error) {
	return newIntent("submit message", sessionPath(session, "/events"), fields)
}
func NewCreation(fields map[string]string) (*OperationHandle, error) {
	request := make(map[string]any, len(fields))
	for key, value := range fields {
		request[key] = value
	}
	return newIntent("create session", "/sessions", request)
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
	receipt, err := RequestOperation[OperationReceipt](ctx, conn, Operation{Name: "query operation", Method: http.MethodGet, Path: "/operations/" + url.PathEscape(id), Policy: ReadRecovery})
	if err == nil && (receipt.OperationID != id || (receipt.Status != "accepted" && receipt.Status != "rejected")) {
		return OperationReceipt{}, errors.New("invalid operation receipt")
	}
	return receipt, err
}

// ResolveOperation only reads the original receipt; it never submits another request.
func ResolveOperation(ctx context.Context, conn *Connection, handle *OperationHandle) (OperationReceipt, error) {
	return GetOperation(ctx, conn, handle.ID)
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
		receipt, lookupErr := GetOperation(reqCtx, conn, handle.ID)
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
	if decodeErr = required(fields, "operationId", &id); decodeErr != nil || id != handle.ID {
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
