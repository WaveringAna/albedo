package daemon

import (
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

type EndpointProvider interface {
	BaseURL() string
	AuthToken() string
	Refresh(ctx context.Context) error
}

type StaticEndpoint struct {
	URL   string
	Token string
}

func (s StaticEndpoint) BaseURL() string {
	return strings.TrimRight(s.URL, "/")
}

func (s StaticEndpoint) AuthToken() string {
	return s.Token
}

func (s StaticEndpoint) Refresh(ctx context.Context) error {
	return errors.New("Cannot reconnect automatically to a fixed server address.")
}

type ReconnectingTransport struct {
	Provider EndpointProvider
	Base     http.RoundTripper
}

func (t *ReconnectingTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	base := t.Base
	if base == nil {
		base = http.DefaultTransport
	}

	res, err := base.RoundTrip(req)
	status := 0
	if res != nil {
		status = res.StatusCode
	}

	if t.Provider != nil && req.URL != nil && req.URL.Path != "/shutdown" && !strings.HasSuffix(req.URL.Path, "/open") && isStaleDaemon(err, status) {
		if refreshErr := t.Provider.Refresh(req.Context()); refreshErr == nil {
			if res != nil {
				_ = res.Body.Close()
			}
			newReq := req.Clone(req.Context())
			newBase := t.Provider.BaseURL()
			if parsed, parseErr := url.Parse(newBase); parseErr == nil && newReq.URL != nil {
				newReq.URL.Scheme = parsed.Scheme
				newReq.URL.Host = parsed.Host
				newReq.Host = parsed.Host
			}
			if token := t.Provider.AuthToken(); token != "" {
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

func NewReconnectingClient(provider EndpointProvider) *http.Client {
	return &http.Client{
		Transport: &ReconnectingTransport{
			Provider: provider,
			Base: &http.Transport{
				Proxy: http.ProxyFromEnvironment,
			},
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
	var opErr *net.OpError
	if errors.As(err, &opErr) {
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

func doAuthenticatedRequest(client *http.Client, token string, req *http.Request) (*http.Response, error) {
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	return client.Do(req)
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
		return nil, fmt.Errorf("Albedo returned more data than this client can read (limit: %d bytes).", limit)
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
		return zero, errors.New("Not connected to Albedo.")
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

	res, err := doAuthenticatedRequest(conn.HTTPClient(), conn.Token(), req)
	if err != nil {
		return zero, err
	}
	defer res.Body.Close()

	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return zero, readHTTPError(res, 50*1024*1024)
	}
	respData, err := readBounded(res.Body, 50*1024*1024)
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
