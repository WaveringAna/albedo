package daemon

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"syscall"
	"time"
)

// RetryPolicy controls application recovery. Audited read-only GET requests
// may also be recovered internally by net/http on a reused connection.
type RetryPolicy uint8

const (
	NoRecovery RetryPolicy = iota
	ReadRecovery
	AuthRecovery
	ReceiptRecovery
)

type Operation struct {
	Handle *OperationHandle
	Body   any
	Name   string
	Method string
	Path   string
	Policy RetryPolicy
}

func newHTTPClient() *http.Client {
	return &http.Client{
		Transport:     &http.Transport{Proxy: http.ProxyFromEnvironment},
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
	}
}

func isConnectionError(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return false
	}
	if errors.Is(err, io.EOF) ||
		errors.Is(err, syscall.ECONNREFUSED) ||
		errors.Is(err, syscall.ECONNRESET) ||
		errors.Is(err, syscall.EPIPE) ||
		errors.Is(err, net.ErrClosed) {
		return true
	}
	if _, ok := errors.AsType[*net.OpError](err); ok {
		return true
	}
	msg := err.Error()
	return strings.Contains(msg, "connection refused") ||
		strings.Contains(msg, "connection reset") ||
		strings.Contains(msg, "broken pipe") ||
		strings.Contains(msg, "EOF")
}

// responseLimits preserves each endpoint's accepted status and bounded reads.
// A zero successStatus accepts any 2xx response.
type responseLimits struct {
	status          *int
	successStatuses []int
	successStatus   int
	bodyBytes       int64
	errorBytes      int64
}

// operationRequest binds the address and credentials to one immutable snapshot.
func operationRequest(ctx context.Context, snapshot ConnectionSnapshot, operation Operation, payload []byte) (*http.Request, error) {
	var reader io.Reader
	if payload != nil {
		reader = bytes.NewReader(payload)
	}
	req, err := http.NewRequestWithContext(ctx, operation.Method, fmt.Sprintf("http://127.0.0.1:%d", snapshot.Port)+operation.Path, reader)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if snapshot.Token != "" {
		req.Header.Set("Authorization", "Bearer "+snapshot.Token)
	}
	// A mutation must never become replayable through net/http's pooled-connection retry.
	// Explicit application recovery constructs a fresh request from payload instead.
	if operation.Policy != ReadRecovery {
		req.GetBody = nil
	}
	return req, nil
}

func encodeOperation(operation Operation) ([]byte, error) {
	if operation.Body == nil {
		return nil, nil
	}
	return json.Marshal(operation.Body)
}

func recoverOperation(ctx context.Context, conn *Connection, operation Operation, snapshot ConnectionSnapshot, failure error) bool {
	if operation.Policy == NoRecovery || ctx.Err() != nil {
		return false
	}
	apiError, rejected := errors.AsType[*APIError](failure)
	authRefusal := rejected && apiError.StatusCode == http.StatusForbidden && apiError.Code == "authentication_required"
	if !authRefusal && (operation.Policy != ReadRecovery || !isConnectionError(failure)) {
		return false
	}
	if conn.Refresh(ctx) != nil {
		return false
	}
	latest := conn.Snapshot()
	return !authRefusal || latest.Port != snapshot.Port || latest.Token != snapshot.Token
}

func uncertainOperation(operation Operation, failure error) error {
	if operation.Policy == ReadRecovery {
		return failure
	}
	return &UncertainOutcomeError{Operation: operation.Name, Cause: failure, Handle: operation.Handle}
}

// requestBytes owns every response until its bounded body has been read.
func requestBytes(ctx context.Context, conn *Connection, operation Operation, limits responseLimits) ([]byte, error) {
	payload, err := encodeOperation(operation)
	if err != nil {
		return nil, err
	}
	for attempt := range 2 {
		if canceled := ctx.Err(); canceled != nil {
			return nil, canceled
		}
		snapshot := conn.Snapshot()
		req, err := operationRequest(ctx, snapshot, operation, payload)
		if err != nil {
			return nil, err
		}
		if canceled := ctx.Err(); canceled != nil {
			return nil, canceled
		}
		res, err := conn.HTTPClient().Do(req)
		if err != nil {
			if attempt == 0 && recoverOperation(ctx, conn, operation, snapshot, err) {
				continue
			}
			if canceled := ctx.Err(); canceled != nil {
				err = errors.Join(err, canceled)
			}
			return nil, uncertainOperation(operation, err)
		}
		success := (limits.successStatus == 0 && res.StatusCode >= 200 && res.StatusCode < 300) || res.StatusCode == limits.successStatus
		if limits.status != nil {
			*limits.status = res.StatusCode
		}
		if len(limits.successStatuses) > 0 {
			success = false
			for _, expected := range limits.successStatuses {
				if res.StatusCode == expected {
					success = true
				}
			}
		}
		var body []byte
		if success {
			body, err = readBounded(res.Body, limits.bodyBytes)
			if err != nil && operation.Policy != ReadRecovery {
				err = &ProtocolError{Code: "invalid_response", Operation: operation.Name, Cause: err}
			}
		} else {
			if res.StatusCode >= 200 && res.StatusCode < 300 && operation.Policy != ReadRecovery {
				err = invalidResponse(operation, "status", fmt.Errorf("unexpected HTTP status %d", res.StatusCode))
			} else {
				err = readHTTPError(res, limits.errorBytes)
			}
		}
		_ = res.Body.Close()
		if err == nil {
			return body, nil
		}
		if attempt == 0 && recoverOperation(ctx, conn, operation, snapshot, err) {
			continue
		}
		if canceled := ctx.Err(); canceled != nil {
			err = errors.Join(err, canceled)
		}
		if success || res.StatusCode >= 500 {
			return nil, uncertainOperation(operation, err)
		}
		return nil, err
	}
	panic("unreachable retry budget")
}

type streamLimits struct {
	lineBytes  int
	errorBytes int64
}

// Recovery ends as soon as a successful stream is accepted; events are never replayed here.
func scanEventStream(ctx context.Context, conn *Connection, operation Operation, limits streamLimits, consume func(*bufio.Scanner) error) error {
	for attempt := range 2 {
		if err := ctx.Err(); err != nil {
			return err
		}
		snapshot := conn.Snapshot()
		req, err := operationRequest(ctx, snapshot, operation, nil)
		if err != nil {
			return err
		}
		req.Header.Set("Accept", "text/event-stream")
		res, err := conn.HTTPClient().Do(req)
		if err != nil {
			if attempt == 0 && recoverOperation(ctx, conn, operation, snapshot, err) {
				continue
			}
			if canceled := ctx.Err(); canceled != nil {
				err = errors.Join(err, canceled)
			}
			return err
		}
		if res.StatusCode != http.StatusOK {
			if limits.errorBytes == 0 {
				apiError := &APIError{StatusCode: res.StatusCode}
				if res.StatusCode == http.StatusForbidden && res.Header.Get("Albedo-Error-Code") == "authentication_required" {
					apiError.Code = "authentication_required"
				}
				err = apiError
			} else {
				err = readHTTPError(res, limits.errorBytes)
			}
			_ = res.Body.Close()
			if attempt == 0 && recoverOperation(ctx, conn, operation, snapshot, err) {
				continue
			}
			if canceled := ctx.Err(); canceled != nil {
				err = errors.Join(err, canceled)
			}
			return err
		}
		defer res.Body.Close()
		scanner := bufio.NewScanner(res.Body)
		scanner.Buffer(make([]byte, 64*1024), limits.lineBytes)
		if err := consume(scanner); err != nil {
			return err
		}
		return scanner.Err()
	}
	panic("unreachable retry budget")
}

func readHTTPError(res *http.Response, limit int64) error {
	body, err := readBounded(res.Body, limit)
	if err != nil {
		return &APIError{StatusCode: res.StatusCode, Cause: err}
	}
	return decodeAPIError(res.StatusCode, body)
}

func readBounded(r io.Reader, limit int64) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(r, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("response exceeds this client's read limit (%d bytes)", limit)
	}
	return data, nil
}

func RequestOperation[T any](ctx context.Context, conn *Connection, operation Operation) (T, error) {
	var zero T
	if conn == nil {
		return zero, errors.New("not connected to Albedo")
	}
	if ctx == nil {
		ctx = context.Background()
	}
	reqCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	respData, err := requestBytes(reqCtx, conn, operation, responseLimits{bodyBytes: 50 * 1024 * 1024, errorBytes: 50 * 1024 * 1024})
	if err != nil {
		return zero, err
	}
	var result T
	if len(respData) > 0 {
		if err := json.Unmarshal(respData, &result); err != nil {
			return zero, uncertainOperation(operation, err)
		}
	}
	return result, nil
}
