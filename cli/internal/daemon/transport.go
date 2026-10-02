package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"time"
)

// executeMutation validates after requestBytes finishes authentication recovery.
// Covered operations apply receipt recovery around this single attempt.
func executeMutation(ctx context.Context, conn *Connection, operation operation, statuses []int, decode func([]byte, int) error) error {
	if conn == nil {
		return errors.New("not connected to Albedo")
	}
	if ctx == nil {
		ctx = context.Background()
	}
	reqCtx := ctx
	if deadline, ok := ctx.Deadline(); !ok || time.Until(deadline) > 20*time.Second {
		var cancel context.CancelFunc
		reqCtx, cancel = context.WithTimeout(ctx, 20*time.Second)
		defer cancel()
	}
	status := 0
	body, err := requestBytes(reqCtx, conn, operation, responseLimits{successStatuses: statuses, status: &status, bodyBytes: 50 * 1024 * 1024, errorBytes: 64 * 1024})
	if err != nil {
		return err
	}
	if err = decode(body, status); err != nil {
		field := ""
		if detail, ok := errors.AsType[*responseFieldError](err); ok {
			field = detail.field
		} else if detail, ok := errors.AsType[*json.UnmarshalTypeError](err); ok {
			field = detail.Field
		}
		return invalidResponse(operation, field, err)
	}
	return nil
}

func decodeAck(data []byte, _ int) error {
	var wire struct {
		OK *bool `json:"ok"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	if wire.OK == nil || !*wire.OK {
		return fieldError("ok")
	}
	return nil
}

func acknowledge(ctx context.Context, conn *Connection, operation operation) error {
	return executeMutation(ctx, conn, operation, []int{http.StatusOK}, decodeAck)
}

func sessionPath(id, tail string) string { return "/sessions/" + url.PathEscape(id) + tail }

func executeRead(ctx context.Context, conn *Connection, operation operation, decode func([]byte) error) error {
	if conn == nil {
		return errors.New("not connected to Albedo")
	}
	if ctx == nil {
		ctx = context.Background()
	}
	requestCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	body, err := requestBytes(requestCtx, conn, operation, responseLimits{successStatus: http.StatusOK, bodyBytes: 50 * 1024 * 1024, errorBytes: 64 * 1024})
	if err != nil {
		return err
	}
	if err = decode(body); err != nil {
		field := ""
		if detail, ok := errors.AsType[*responseFieldError](err); ok {
			field = detail.field
		} else if detail, ok := errors.AsType[*json.UnmarshalTypeError](err); ok {
			field = detail.Field
		}
		return &ProtocolError{Code: "invalid_response", Operation: operation.Name, Field: field, Cause: err}
	}
	return nil
}
