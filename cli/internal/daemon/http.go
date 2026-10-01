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
	"net/url"
	"strings"
	"syscall"
	"time"
)

type reconnectingTransport struct {
	conn *Connection
	base *http.Transport
}

func (t *reconnectingTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	base := t.base

	res, err := base.RoundTrip(req)
	status := 0
	if res != nil {
		status = res.StatusCode
	}

	// Retrying shutdown could stop a replacement daemon. The settings /open
	// route increments an open count and its contract forbids automatic retries.
	if req.URL != nil && req.URL.Path != "/shutdown" && !strings.HasSuffix(req.URL.Path, "/open") && isStaleDaemon(err, status) {
		if refreshErr := t.conn.Refresh(req.Context()); refreshErr == nil {
			if res != nil {
				_ = res.Body.Close()
			}
			newReq := req.Clone(req.Context())
			newBase := t.conn.BaseURL()
			if parsed, parseErr := url.Parse(newBase); parseErr == nil && newReq.URL != nil {
				newReq.URL.Scheme = parsed.Scheme
				newReq.URL.Host = parsed.Host
				newReq.Host = parsed.Host
			}
			if token := t.conn.Token(); token != "" {
				newReq.Header.Set("Authorization", "Bearer "+token)
			}
			if req.GetBody != nil {
				body, bodyErr := req.GetBody()
				if bodyErr != nil {
					return nil, bodyErr
				}
				newReq.Body = body
			}
			return base.RoundTrip(newReq)
		}
	}
	return res, err
}

func (t *reconnectingTransport) CloseIdleConnections() {
	t.base.CloseIdleConnections()
}

func newHTTPClient(conn *Connection) *http.Client {
	return &http.Client{
		Transport: &reconnectingTransport{
			conn: conn,
			base: &http.Transport{Proxy: http.ProxyFromEnvironment},
		},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
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

func isStaleDaemon(err error, statusCode int) bool {
	if statusCode == http.StatusUnauthorized || statusCode == http.StatusForbidden {
		return true
	}
	return isConnectionError(err)
}

func newJSONRequest(ctx context.Context, method, url string, body any) (*http.Request, error) {
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		// A bytes.Reader lets net/http populate GetBody for a reconnect retry.
		reader = bytes.NewReader(encoded)
	}
	req, err := http.NewRequestWithContext(ctx, method, url, reader)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return req, nil
}

func doAuthenticatedRequest(conn *Connection, req *http.Request) (*http.Response, error) {
	if token := conn.Token(); token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	return conn.HTTPClient().Do(req)
}

// responseLimits preserves each endpoint's accepted status and bounded reads.
// A zero successStatus accepts any 2xx response.
type responseLimits struct {
	successStatus int
	bodyBytes     int64
	errorBytes    int64
}

// requestBytes owns the response until its bounded body has been read.
func requestBytes(conn *Connection, req *http.Request, limits responseLimits) ([]byte, error) {
	res, err := doAuthenticatedRequest(conn, req)
	if err != nil {
		return nil, err
	}
	// Read and status errors describe the operation; closing cannot undo it.
	defer res.Body.Close()
	if (limits.successStatus != 0 && res.StatusCode != limits.successStatus) ||
		(limits.successStatus == 0 && (res.StatusCode < 200 || res.StatusCode >= 300)) {
		return nil, readHTTPError(res, limits.errorBytes)
	}
	return readBounded(res.Body, limits.bodyBytes)
}

type streamLimits struct {
	lineBytes  int
	errorBytes int64
}

// scanEventStream owns the response while consume scans it. The scanner is
// borrowed for that call only; callbacks never own or close the response.
func scanEventStream(conn *Connection, req *http.Request, limits streamLimits, consume func(*bufio.Scanner) error) error {
	req.Header.Set("Accept", "text/event-stream")
	res, err := doAuthenticatedRequest(conn, req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		if limits.errorBytes == 0 {
			// Some error streams never finish, so only inspect their status.
			return &APIError{StatusCode: res.StatusCode}
		}
		return readHTTPError(res, limits.errorBytes)
	}
	scanner := bufio.NewScanner(res.Body)
	scanner.Buffer(make([]byte, 64*1024), limits.lineBytes)
	if err := consume(scanner); err != nil {
		return err
	}
	return scanner.Err()
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

func Request[T any](ctx context.Context, conn *Connection, path string, body any) (T, error) {
	method := http.MethodGet
	if body != nil {
		method = http.MethodPost
	}
	return RequestMethod[T](ctx, conn, method, path, body)
}

func RequestMethod[T any](ctx context.Context, conn *Connection, method, path string, body any) (T, error) {
	var zero T
	if conn == nil {
		return zero, errors.New("not connected to Albedo")
	}
	if ctx == nil {
		ctx = context.Background()
	}

	reqCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()

	reqURL := conn.BaseURL() + path
	req, err := newJSONRequest(reqCtx, method, reqURL, body)
	if err != nil {
		return zero, err
	}
	req.Header.Set("Content-Type", "application/json")

	respData, err := requestBytes(conn, req, responseLimits{bodyBytes: 50 * 1024 * 1024, errorBytes: 50 * 1024 * 1024})
	if err != nil {
		return zero, err
	}

	var result T
	if len(respData) > 0 {
		if err := json.Unmarshal(respData, &result); err != nil {
			return zero, err
		}
	}
	return result, nil
}
