package daemon

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"slices"
	"strings"
	"syscall"
	"time"
)

// retryPolicy controls application recovery. Audited read-only GET requests
// may also be recovered internally by net/http on a reused connection.
type retryPolicy uint8

const (
	noRecovery retryPolicy = iota
	readRecovery
	authRecovery
	receiptRecovery
)

type operation struct {
	BuildRequest func(string, io.Reader) (*http.Request, error)
	Handle       *OperationHandle
	Body         any
	Name         string
	Method       string
	Path         string
	Policy       retryPolicy
	Headers      http.Header
	Validator    *string
	Timeout      time.Duration
	Capability   string
}

func (c *Connection) operationEndpoint(op operation) (ConnectionSnapshot, error) {
	if c == nil {
		return ConnectionSnapshot{}, errors.New("not connected to Albedo")
	}
	state := c.state.Load()
	if state == nil {
		return ConnectionSnapshot{}, errors.New("not connected to Albedo")
	}
	if op.Capability != "" {
		if state.capabilities == nil {
			return ConnectionSnapshot{}, &ProtocolError{Code: "not_attached", Operation: op.Name, Cause: errors.New("attach to the daemon before invoking optional APIs")}
		}
		if state.capabilities[op.Capability] < 1 {
			return ConnectionSnapshot{}, &UpgradeRequiredError{Feature: "for " + op.Capability}
		}
	}
	return state.endpoint, nil
}

func (c *Connection) capability(name string) int64 {
	if state := c.state.Load(); state != nil {
		return state.capabilities[name]
	}
	return 0
}

func newHTTPClient() *http.Client {
	return &http.Client{
		Transport:     codingTransport{base: &http.Transport{Proxy: http.ProxyFromEnvironment}},
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
func operationRequest(ctx context.Context, snapshot ConnectionSnapshot, operation operation, payload []byte) (*http.Request, error) {
	var reader io.Reader
	if payload != nil {
		reader = bytes.NewReader(payload)
	}
	base := fmt.Sprintf("http://127.0.0.1:%d/", snapshot.Port)
	var req *http.Request
	var err error
	if operation.BuildRequest != nil {
		req, err = operation.BuildRequest(base, reader)
		if err == nil {
			req = req.WithContext(ctx)
		}
	} else {
		req, err = http.NewRequestWithContext(ctx, operation.Method, strings.TrimSuffix(base, "/")+operation.Path, reader)
	}
	if err != nil {
		return nil, err
	}
	if req.Header.Get("Content-Type") == "" {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("Accept", "application/json")
	for name, values := range operation.Headers {
		req.Header[name] = slices.Clone(values)
	}
	if snapshot.Token != "" {
		req.Header.Set("Authorization", "Bearer "+snapshot.Token)
	}
	// A mutation must never become replayable through net/http's pooled-connection retry.
	// Explicit application recovery constructs a fresh request from payload instead.
	if operation.Policy != readRecovery {
		req.GetBody = nil
	}
	return req, nil
}

func encodeOperation(operation operation) ([]byte, error) {
	if operation.Body == nil {
		return nil, nil
	}
	return json.Marshal(operation.Body)
}

func recoverOperation(ctx context.Context, conn *Connection, operation operation, snapshot ConnectionSnapshot, failure error) (bool, error) {
	if operation.Policy == noRecovery || ctx.Err() != nil {
		return false, nil
	}
	apiError, rejected := errors.AsType[*APIError](failure)
	authRefusal := rejected && apiError.StatusCode == http.StatusUnauthorized && apiError.Code == "authentication_required"
	if !authRefusal && (operation.Policy != readRecovery || !isConnectionError(failure)) {
		return false, nil
	}
	if conn.rediscover == nil {
		return false, nil
	}
	if err := conn.Refresh(ctx); err != nil {
		return false, err
	}
	latest := conn.Snapshot()
	return !authRefusal || latest.Port != snapshot.Port || latest.Token != snapshot.Token, nil
}

func uncertainOperation(operation operation, failure error) error {
	if operation.Policy == readRecovery || operation.Method == http.MethodGet {
		return failure
	}
	return &UncertainOutcomeError{Operation: operation.Name, Cause: failure, Handle: operation.Handle}
}

// requestBytes owns every response until its bounded body has been read.
func requestBytes(ctx context.Context, conn *Connection, operation operation, limits responseLimits) ([]byte, error) {
	payload, err := encodeOperation(operation)
	if err != nil {
		return nil, err
	}
	for attempt := range 2 {
		if canceled := ctx.Err(); canceled != nil {
			return nil, canceled
		}
		snapshot, err := conn.operationEndpoint(operation)
		if err != nil {
			return nil, err
		}
		sent, encoding := requestBody(conn, payload)
		req, err := operationRequest(ctx, snapshot, operation, sent)
		if err != nil {
			return nil, err
		}
		if encoding != "" {
			req.Header.Set("Content-Encoding", encoding)
		}
		if canceled := ctx.Err(); canceled != nil {
			return nil, canceled
		}
		operation.Method = req.Method
		res, err := conn.HTTPClient().Do(req)
		if err != nil {
			if attempt == 0 {
				recovered, recoveryErr := recoverOperation(ctx, conn, operation, snapshot, err)
				if recoveryErr != nil {
					return nil, errors.Join(err, recoveryErr)
				}
				if recovered {
					continue
				}
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
			if operation.Validator != nil {
				*operation.Validator = res.Header.Get("ETag")
			}
			body, err = readBounded(res.Body, limits.bodyBytes)
			if err != nil && operation.Policy != readRecovery {
				err = &ProtocolError{Code: "invalid_response", Operation: operation.Name, Cause: err}
			}
		} else {
			if res.StatusCode >= 200 && res.StatusCode < 300 && operation.Policy != readRecovery {
				err = invalidResponse(operation, "status", fmt.Errorf("unexpected HTTP status %d", res.StatusCode))
			} else {
				err = readHTTPError(res, limits.errorBytes)
			}
		}
		_ = res.Body.Close()
		if err == nil {
			return body, nil
		}
		if attempt == 0 {
			recovered, recoveryErr := recoverOperation(ctx, conn, operation, snapshot, err)
			if recoveryErr != nil {
				return nil, errors.Join(err, recoveryErr)
			}
			if recovered {
				continue
			}
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
	requireSSE bool
	lineBytes  int
	errorBytes int64
}

// Recovery ends as soon as a successful stream is accepted; events are never replayed here.
func scanEventStream(ctx context.Context, conn *Connection, operation operation, limits streamLimits, consume func(*bufio.Scanner) error) error {
	for attempt := range 2 {
		if err := ctx.Err(); err != nil {
			return err
		}
		snapshot, err := conn.operationEndpoint(operation)
		if err != nil {
			return err
		}
		req, err := operationRequest(ctx, snapshot, operation, nil)
		if err != nil {
			return err
		}
		req.Header.Set("Accept", "text/event-stream")
		operation.Method = req.Method
		res, err := conn.HTTPClient().Do(req)
		if err != nil {
			if attempt == 0 {
				recovered, recoveryErr := recoverOperation(ctx, conn, operation, snapshot, err)
				if recoveryErr != nil {
					return errors.Join(err, recoveryErr)
				}
				if recovered {
					continue
				}
			}
			if canceled := ctx.Err(); canceled != nil {
				err = errors.Join(err, canceled)
			}
			return err
		}
		if res.StatusCode != http.StatusOK {
			if limits.errorBytes == 0 {
				apiError := &APIError{StatusCode: res.StatusCode}
				if res.StatusCode == http.StatusUnauthorized && strings.HasPrefix(res.Header.Get("WWW-Authenticate"), "Bearer") {
					apiError.Code = "authentication_required"
				}
				err = apiError
			} else {
				err = readHTTPError(res, limits.errorBytes)
			}
			_ = res.Body.Close()
			if attempt == 0 {
				recovered, recoveryErr := recoverOperation(ctx, conn, operation, snapshot, err)
				if recoveryErr != nil {
					return errors.Join(err, recoveryErr)
				}
				if recovered {
					continue
				}
			}
			if canceled := ctx.Err(); canceled != nil {
				err = errors.Join(err, canceled)
			}
			return err
		}
		if limits.requireSSE {
			mediaType, _, parseErr := mime.ParseMediaType(res.Header.Get("Content-Type"))
			if parseErr != nil || mediaType != "text/event-stream" {
				_ = res.Body.Close()
				return streamFailure(StreamProtocol, fmt.Errorf("invalid stream content type %q", res.Header.Get("Content-Type")))
			}
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
