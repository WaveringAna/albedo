package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
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
	timeout := operation.Timeout
	if timeout <= 0 {
		timeout = 20 * time.Second
	}
	reqCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	status := 0
	body, err := requestBytes(reqCtx, conn, operation, responseLimits{successStatuses: statuses, status: &status, bodyBytes: 1024 * 1024, errorBytes: 64 * 1024})
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

func executeRead(ctx context.Context, conn *Connection, operation operation, decode func([]byte) error) error {
	if conn == nil {
		return errors.New("not connected to Albedo")
	}
	if ctx == nil {
		ctx = context.Background()
	}
	requestCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	body, err := requestBytes(requestCtx, conn, operation, responseLimits{successStatus: http.StatusOK, bodyBytes: 1024 * 1024, errorBytes: 64 * 1024})
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
