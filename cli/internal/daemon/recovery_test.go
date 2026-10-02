// Connection snapshot races, refresh wait cancellation, and pooled transport
// retries need deterministic gates that a live daemon cannot reliably expose.
package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

type captureTransport struct {
	entered chan *http.Request
	release chan struct{}
}

func (transport captureTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	transport.entered <- request
	<-transport.release
	return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(`{"ok":true}`)), Header: make(http.Header)}, nil
}

func TestOperationUsesCapturedAddressAndToken(t *testing.T) {
	conn := NewConnection(ConnectionSnapshot{Port: 34567, Token: "old"}, nil)
	transport := captureTransport{entered: make(chan *http.Request), release: make(chan struct{})}
	conn.HTTPClient().Transport = transport
	finished := make(chan error, 1)
	go func() {
		_, err := RequestOperation[any](context.Background(), conn, Operation{Name: "submit", Method: http.MethodPost, Path: "/events", Body: map[string]string{"text": "hello"}, Policy: AuthRecovery})
		finished <- err
	}()
	request := <-transport.entered
	conn.Update(NewConnection(ConnectionSnapshot{Port: 45678, Token: "new"}, nil))
	if request.URL.Host != "127.0.0.1:34567" || request.Header.Get("Authorization") != "Bearer old" {
		t.Errorf("request mixed connection snapshots: %s, %s", request.URL.Host, request.Header.Get("Authorization"))
	}
	close(transport.release)
	if err := <-finished; err != nil {
		t.Fatal(err)
	}
}

func TestPooledMutationAcknowledgementLossIsNotReplayed(t *testing.T) {
	for _, test := range []struct {
		body   any
		name   string
		method string
	}{
		{name: "submission", method: http.MethodPost, body: map[string]string{"text": "hello"}},
		{name: "sign-in start", method: http.MethodPost},
		{name: "delete", method: http.MethodDelete},
	} {
		t.Run(test.name, func(t *testing.T) {
			var calls atomic.Int32
			var connections atomic.Int32
			server := httptest.NewUnstartedServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				_, _ = io.Copy(io.Discard, request.Body)
				if calls.Add(1) == 1 {
					_, _ = writer.Write([]byte(`{"ok":true}`))
					return
				}
				connection, _, err := writer.(http.Hijacker).Hijack()
				if err != nil {
					t.Error(err)
					return
				}
				_ = connection.Close()
			}))
			server.Config.ConnState = func(_ net.Conn, state http.ConnState) {
				if state == http.StateNew {
					connections.Add(1)
				}
			}
			server.Start()
			defer server.Close()
			conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
			defer conn.HTTPClient().CloseIdleConnections()
			operation := Operation{Name: "submit", Method: test.method, Path: "/mutation", Body: test.body, Policy: AuthRecovery}
			if _, err := RequestOperation[any](context.Background(), conn, operation); err != nil {
				t.Fatal(err)
			}
			_, err := RequestOperation[any](context.Background(), conn, operation)
			if _, ok := errors.AsType[*UncertainOutcomeError](err); !ok {
				t.Fatalf("lost response returned %v", err)
			}
			if calls.Load() != 2 || connections.Load() != 1 {
				t.Fatalf("mutation was replayed or fixture missed reuse: calls=%d connections=%d", calls.Load(), connections.Load())
			}
		})
	}
}

func TestConcurrentOperationsNeverMixConnectionSnapshots(t *testing.T) {
	var failures atomic.Int32
	newServer := func(token string) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
			if request.Header.Get("Authorization") != "Bearer "+token {
				failures.Add(1)
			}
			_, _ = writer.Write([]byte(`{}`))
		}))
	}
	first, second := newServer("first"), newServer("second")
	defer first.Close()
	defer second.Close()
	firstConn := NewConnection(ConnectionSnapshot{Port: first.Listener.Addr().(*net.TCPAddr).Port, Token: "first"}, nil)
	secondConn := NewConnection(ConnectionSnapshot{Port: second.Listener.Addr().(*net.TCPAddr).Port, Token: "second"}, nil)
	conn := NewConnection(firstConn.Snapshot(), nil)
	defer conn.HTTPClient().CloseIdleConnections()
	var readers sync.WaitGroup
	for range 4 {
		readers.Go(func() {
			for range 50 {
				_, err := RequestOperation[any](context.Background(), conn, Operation{Name: "read", Method: http.MethodGet, Path: "/health", Policy: ReadRecovery})
				if err != nil {
					t.Error(err)
				}
			}
		})
	}
	for range 100 {
		conn.Update(secondConn)
		conn.Update(firstConn)
	}
	readers.Wait()
	if failures.Load() != 0 {
		t.Fatalf("%d requests paired address with another daemon's token", failures.Load())
	}
}

// Auth refusal must prove non-admission before a mutation can be dispatched again.
func TestMutationAuthRecoveryBudget(t *testing.T) {
	for _, test := range []struct {
		name       string
		token      string
		status     int
		expected   int32
		marker     bool
		rediscover bool
		repeated   bool
	}{
		{name: "changed credentials", marker: true, status: 403, token: "new", rediscover: true, expected: 2},
		{name: "unchanged credentials", marker: true, status: 403, token: "old", rediscover: true, expected: 1},
		{name: "unmarked refusal", status: 403, token: "new", rediscover: true, expected: 1},
		{name: "unmarked unauthorized", status: 401, token: "new", rediscover: true, expected: 1},
		{name: "marked unauthorized", marker: true, status: 401, token: "new", rediscover: true, expected: 1},
		{name: "no discovery", marker: true, status: 403, token: "new", expected: 1},
		{name: "repeated refusal", marker: true, status: 403, token: "new", rediscover: true, repeated: true, expected: 2},
	} {
		t.Run(test.name, func(t *testing.T) {
			var calls atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				if request.URL.Path == "/health" {
					_, _ = writer.Write([]byte(`{"ok":true,"version":2,"capabilities":["operation_receipts","session_stream_generation","agents_stream_overflow"]}`))
					return
				}
				count := calls.Add(1)
				if count == 1 || test.repeated {
					writer.WriteHeader(test.status)
					if test.marker {
						_, _ = writer.Write([]byte(`{"code":"authentication_required","error":"invalid bearer"}`))
					} else {
						_, _ = writer.Write([]byte(`{"error":"forbidden"}`))
					}
					return
				}
				if request.Header.Get("Authorization") != "Bearer new" {
					t.Errorf("recovery reused old credentials")
				}
				_, _ = writer.Write([]byte(`{"ok":true}`))
			}))
			defer server.Close()
			port := server.Listener.Addr().(*net.TCPAddr).Port
			var rediscover Rediscovery
			if test.rediscover {
				rediscover = func(context.Context) (ConnectionSnapshot, error) {
					return ConnectionSnapshot{Port: port, Token: test.token, Version: 2}, nil
				}
			}
			conn := NewConnection(ConnectionSnapshot{Port: port, Token: "old", Version: 2}, rediscover)
			defer conn.HTTPClient().CloseIdleConnections()
			_, err := RequestOperation[any](context.Background(), conn, Operation{Name: "mutate", Method: http.MethodPost, Path: "/mutation", Policy: AuthRecovery})
			if calls.Load() != test.expected {
				t.Fatalf("got %d dispatches, expected %d", calls.Load(), test.expected)
			}
			success := test.expected == 2 && !test.repeated
			if (err == nil) != success {
				t.Fatalf("unexpected result %v", err)
			}
			if !success {
				if _, uncertain := errors.AsType[*UncertainOutcomeError](err); uncertain {
					t.Fatalf("pre-admission rejection reported uncertain: %v", err)
				}
			}
		})
	}
}

func TestReadRecoveryIncludesTruncatedBody(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/health" {
			_, _ = writer.Write([]byte(`{"ok":true,"version":2,"capabilities":["operation_receipts","session_stream_generation","agents_stream_overflow"]}`))
			return
		}
		if calls.Add(1) == 1 {
			writer.Header().Set("Content-Length", "100")
			_, _ = writer.Write([]byte(`{"ok":`))
			return
		}
		_, _ = writer.Write([]byte(`{"ok":true}`))
	}))
	defer server.Close()
	snapshot := ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "token", Version: 2}
	conn := NewConnection(snapshot, func(context.Context) (ConnectionSnapshot, error) { return snapshot, nil })
	defer conn.HTTPClient().CloseIdleConnections()
	result, err := RequestOperation[map[string]bool](context.Background(), conn, Operation{Name: "read", Method: http.MethodGet, Path: "/read", Policy: ReadRecovery})
	if err != nil || !result["ok"] || calls.Load() != 2 {
		t.Fatalf("truncated read did not recover once: %v, %v, %d", result, err, calls.Load())
	}
}

func TestMalformedMutationAcknowledgementIsUncertain(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) { calls.Add(1); _, _ = writer.Write([]byte(`{"ok":`)) }))
	defer server.Close()
	conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
	defer conn.HTTPClient().CloseIdleConnections()
	_, err := RequestOperation[any](context.Background(), conn, Operation{Name: "mutate", Method: http.MethodPost, Path: "/mutation", Policy: AuthRecovery})
	if _, ok := errors.AsType[*UncertainOutcomeError](err); !ok {
		t.Fatalf("invalid acknowledgement returned %v", err)
	}
	if _, ok := errors.AsType[*json.SyntaxError](err); !ok {
		t.Fatalf("decode cause lost: %v", err)
	}
	if calls.Load() != 1 {
		t.Fatalf("invalid acknowledgement replayed %d times", calls.Load())
	}
}

func TestRecordOpenDoesNotRecoverAuthentication(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/health" {
			_, _ = writer.Write([]byte(`{"ok":true,"version":2,"capabilities":["operation_receipts","session_stream_generation","agents_stream_overflow"]}`))
			return
		}
		calls.Add(1)
		writer.WriteHeader(http.StatusForbidden)
		_, _ = writer.Write([]byte(`{"code":"authentication_required"}`))
	}))
	defer server.Close()
	snapshot := ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "new", Version: 2}
	replacement := snapshot
	snapshot.Token = "old"
	conn := NewConnection(snapshot, func(context.Context) (ConnectionSnapshot, error) { return replacement, nil })
	defer conn.HTTPClient().CloseIdleConnections()
	_, err := RecordOpen(context.Background(), conn, "test")
	if err == nil || calls.Load() != 1 || conn.Token() != "old" {
		t.Fatalf("open recovered authentication: %v, %d, %s", err, calls.Load(), conn.Token())
	}
}

type trackedResponseBody struct {
	io.Reader
	closed bool
}

func (body *trackedResponseBody) Close() error { body.closed = true; return nil }

type responseTransport struct{ response *http.Response }

func (transport responseTransport) RoundTrip(_ *http.Request) (*http.Response, error) {
	return transport.response, nil
}

func TestOperationClosesResponsesAndBoundsReads(t *testing.T) {
	for _, test := range []struct {
		name    string
		content string
		status  int
		success bool
	}{
		{name: "success", status: 200, content: "ok", success: true},
		{name: "oversized success", status: 200, content: "123456"},
		{name: "rejection", status: 403, content: `{"error":"no"}`},
		{name: "server failure", status: 503, content: "bad"},
	} {
		t.Run(test.name, func(t *testing.T) {
			body := &trackedResponseBody{Reader: strings.NewReader(test.content)}
			conn := NewConnection(ConnectionSnapshot{Port: 12345}, nil)
			conn.HTTPClient().Transport = responseTransport{response: &http.Response{StatusCode: test.status, Body: body, Header: make(http.Header)}}
			_, err := requestBytes(context.Background(), conn, Operation{Name: "mutate", Method: http.MethodPost, Path: "/mutation", Policy: AuthRecovery}, responseLimits{bodyBytes: 4, errorBytes: 4})
			if !body.closed {
				t.Fatal("operation leaked response body")
			}
			if (err == nil) != test.success {
				t.Fatalf("unexpected result %v", err)
			}
			if test.name == "oversized success" {
				if _, uncertain := errors.AsType[*UncertainOutcomeError](err); !uncertain {
					t.Fatalf("lost acknowledgement not uncertain: %v", err)
				}
			}
		})
	}
}

func TestMutationRedirectIsNotFollowed(t *testing.T) {
	var admissions atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		admissions.Add(1)
		_, _ = writer.Write([]byte(`{}`))
	}))
	defer target.Close()
	source := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		http.Redirect(writer, request, target.URL, http.StatusTemporaryRedirect)
	}))
	defer source.Close()
	conn := NewConnection(ConnectionSnapshot{Port: source.Listener.Addr().(*net.TCPAddr).Port}, nil)
	defer conn.HTTPClient().CloseIdleConnections()
	_, err := RequestOperation[any](context.Background(), conn, Operation{Name: "mutate", Method: http.MethodPost, Path: "/mutation", Body: map[string]string{"text": "hello"}, Policy: AuthRecovery})
	failure, ok := errors.AsType[*APIError](err)
	if !ok || failure.StatusCode != 307 || admissions.Load() != 0 {
		t.Fatalf("redirect policy changed: %v admissions=%d", err, admissions.Load())
	}
}
