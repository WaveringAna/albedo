//go:build unix

// This proxy waits for real daemon admission before corrupting a response.
// It preserves effect evidence while exposing acknowledgement-loss races.
package e2e

import (
	"albedo/cli/internal/daemon"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"maps"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

type acknowledgementFault string

const (
	expiredAcknowledgement     acknowledgementFault = "expired"
	dropAcknowledgement        acknowledgementFault = "drop"
	hideReceiptAcknowledgement acknowledgementFault = "drop-and-hide-receipt"
	unresolvedAcknowledgement  acknowledgementFault = "unresolved"
	truncateAcknowledgement    acknowledgementFault = "truncate"
	rejectAcknowledgement      acknowledgementFault = "server-error"
	cancelAcknowledgement      acknowledgementFault = "cancel"
	emptyAcknowledgement       acknowledgementFault = "empty"
	malformedAcknowledgement   acknowledgementFault = "malformed"
	missingAcknowledgement     acknowledgementFault = "missing-fields"
	negativeAcknowledgement    acknowledgementFault = "negative"
	wrongStatusAcknowledgement acknowledgementFault = "wrong-status"
)

type acknowledgementProxy struct {
	expireReceipt atomic.Bool
	allowReceipt  atomic.Bool
	failure       error
	connection    *daemon.Connection
	admitted      chan struct{}
	responses     [][]byte
	requests      []string
	mu            sync.Mutex
}

func cutAcknowledgement(t *testing.T, path string, fault acknowledgementFault) *acknowledgementProxy {
	t.Helper()
	return mutateAcknowledgement(t, path, fault, nil, nil)
}

func mutateAcknowledgement(t *testing.T, path string, fault acknowledgementFault, matches func([]byte) bool, transform func([]byte) ([]byte, error)) *acknowledgementProxy {
	t.Helper()
	upstream := conn(t).Snapshot()
	destination, err := url.Parse(conn(t).BaseURL())
	if err != nil {
		t.Fatal(err)
	}
	proxy := &acknowledgementProxy{admitted: make(chan struct{}, 1)}
	transport := &http.Transport{}
	t.Cleanup(transport.CloseIdleConnections)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requestBody, bodyErr := io.ReadAll(request.Body)
		if bodyErr != nil {
			http.Error(writer, bodyErr.Error(), http.StatusBadRequest)
			return
		}
		proxy.mu.Lock()
		streamRequest := request.Header.Get("Accept") == "text/event-stream"
		receiptQuery := request.Method == http.MethodGet && !streamRequest && slices.Contains(proxy.requests, "PUT "+request.URL.Path)
		hideReceipt := fault == hideReceiptAcknowledgement && receiptQuery && !slices.Contains(proxy.requests, "GET "+request.URL.Path)
		if !streamRequest {
			proxy.requests = append(proxy.requests, request.Method+" "+request.URL.Path)
		}
		proxy.mu.Unlock()
		if receiptQuery {
			switch {
			case fault == unresolvedAcknowledgement && !proxy.allowReceipt.Load():
				writer.WriteHeader(http.StatusServiceUnavailable)
				_, _ = writer.Write([]byte(`{"type":"about:blank","title":"Unavailable","status":503,"code":"receipt_unavailable","detail":"receipt unavailable"}`))
				return
			case fault == expiredAcknowledgement || proxy.expireReceipt.Load():
				code := "creation_expired"
				if strings.Contains(request.URL.Path, "/inputs/") {
					code = "input_expired"
				}
				writer.WriteHeader(http.StatusGone)
				_, _ = fmt.Fprintf(writer, `{"type":"about:blank","title":"Expired","status":410,"code":%q,"detail":"expired"}`, code)
				return
			case hideReceipt:
				writer.WriteHeader(http.StatusNotFound)
				_, _ = writer.Write([]byte(`{"type":"about:blank","title":"Unknown","status":404,"code":"resource_not_found","detail":"unknown"}`))
				return
			}
		}
		forwarded := request.Clone(request.Context())
		forwarded.Body = http.NoBody
		if len(requestBody) > 0 {
			forwarded.Body = io.NopCloser(bytes.NewReader(requestBody))
		}
		forwarded.ContentLength = int64(len(requestBody))
		forwarded.TransferEncoding = nil
		forwarded.URL.Scheme, forwarded.URL.Host = destination.Scheme, destination.Host
		forwarded.RequestURI = ""
		forwarded.Host = destination.Host
		response, forwardErr := transport.RoundTrip(forwarded)
		if forwardErr != nil {
			proxy.mu.Lock()
			proxy.failure = forwardErr
			proxy.mu.Unlock()
			http.Error(writer, forwardErr.Error(), http.StatusBadGateway)
			return
		}
		defer response.Body.Close()
		if strings.HasPrefix(response.Header.Get("Content-Type"), "text/event-stream") {
			for key, values := range response.Header {
				writer.Header()[key] = values
			}
			writer.WriteHeader(response.StatusCode)
			_ = http.NewResponseController(writer).Flush()
			_, _ = io.Copy(flushingResponseWriter{writer}, response.Body)
			return
		}
		body, readErr := io.ReadAll(io.LimitReader(response.Body, 1<<20))
		if readErr != nil {
			proxy.mu.Lock()
			proxy.failure = readErr
			proxy.mu.Unlock()
			http.Error(writer, readErr.Error(), http.StatusBadGateway)
			return
		}
		pathMatches := request.URL.Path == path
		if path == "/sessions" {
			pathMatches = request.Method == http.MethodPut && strings.HasPrefix(request.URL.Path, "/sessions/") && strings.Count(request.URL.Path, "/") == 2
		}
		if strings.HasSuffix(path, "/") {
			pathMatches = strings.HasPrefix(request.URL.Path, path)
		}
		isMutation := request.Method != http.MethodGet && pathMatches && (matches == nil || matches(requestBody))
		first := false
		if isMutation {
			proxy.mu.Lock()
			first = len(proxy.responses) == 0
			proxy.responses = append(proxy.responses, body)
			if (response.StatusCode < 200 || response.StatusCode >= 300) && !(request.Method == http.MethodPut && response.StatusCode == http.StatusPreconditionFailed) {
				proxy.failure = fmt.Errorf("daemon rejected mutation: %s: %s", response.Status, body)
			}
			proxy.mu.Unlock()
		}
		maps.Copy(writer.Header(), response.Header)
		if isMutation && (first || fault == unresolvedAcknowledgement || fault == expiredAcknowledgement) {
			if first {
				proxy.admitted <- struct{}{}
			}
			if transform != nil {
				transformed, transformErr := transform(body)
				if transformErr != nil {
					proxy.mu.Lock()
					proxy.failure = transformErr
					proxy.mu.Unlock()
					http.Error(writer, transformErr.Error(), http.StatusBadGateway)
					return
				}
				writer.WriteHeader(response.StatusCode)
				_, _ = writer.Write(transformed)
				return
			}
			switch fault {
			case dropAcknowledgement, hideReceiptAcknowledgement, unresolvedAcknowledgement, expiredAcknowledgement:
				socket, _, hijackErr := writer.(http.Hijacker).Hijack()
				if hijackErr == nil {
					_ = socket.Close()
				}
				return
			case truncateAcknowledgement:
				writer.Header().Set("Content-Length", strconv.Itoa(len(body)+1))
				writer.WriteHeader(response.StatusCode)
				_, _ = writer.Write(body[:len(body)/2])
				return
			case rejectAcknowledgement:
				http.Error(writer, "acknowledgement unavailable", http.StatusServiceUnavailable)
				return
			case emptyAcknowledgement:
				writer.WriteHeader(response.StatusCode)
				return
			case malformedAcknowledgement:
				writer.WriteHeader(response.StatusCode)
				_, _ = writer.Write([]byte("{"))
				return
			case missingAcknowledgement:
				writer.WriteHeader(response.StatusCode)
				_, _ = writer.Write([]byte("{}"))
				return
			case negativeAcknowledgement:
				writer.WriteHeader(response.StatusCode)
				_, _ = writer.Write([]byte(`{"admission":"accepted","http_status":false}`))
				return
			case wrongStatusAcknowledgement:
				status := http.StatusCreated
				if response.StatusCode == status {
					status = http.StatusAccepted
				}
				writer.WriteHeader(status)
				_, _ = writer.Write(body)
				return
			case cancelAcknowledgement:
				<-request.Context().Done()
				return
			}
		}
		writer.WriteHeader(response.StatusCode)
		_, _ = writer.Write(body)
	}))
	t.Cleanup(server.Close)
	upstream.Port = server.Listener.Addr().(*net.TCPAddr).Port
	var attachErr error
	proxy.connection, attachErr = daemon.Attach(t.Context(), upstream, func(context.Context) (daemon.ConnectionSnapshot, error) { return upstream, nil })
	if attachErr != nil {
		t.Fatal(attachErr)
	}
	t.Cleanup(proxy.connection.HTTPClient().CloseIdleConnections)
	return proxy
}

func (proxy *acknowledgementProxy) assertSingleEffect(t *testing.T, operationErr error) []byte {
	t.Helper()
	if _, uncertain := errors.AsType[*daemon.UncertainOutcomeError](operationErr); !uncertain {
		t.Fatalf("lost acknowledgement should be uncertain, got %v", operationErr)
	}
	return proxy.acceptedResponse(t)
}

func (proxy *acknowledgementProxy) acceptedResponse(t *testing.T) []byte {
	t.Helper()
	proxy.mu.Lock()
	defer proxy.mu.Unlock()
	if proxy.failure != nil {
		t.Fatal(proxy.failure)
	}
	if len(proxy.responses) != 1 {
		t.Fatalf("daemon admitted %d mutations, want one", len(proxy.responses))
	}
	return slices.Clone(proxy.responses[0])
}

type flushingResponseWriter struct{ http.ResponseWriter }

func (writer flushingResponseWriter) Write(data []byte) (int, error) {
	count, err := writer.ResponseWriter.Write(data)
	if err == nil {
		err = http.NewResponseController(writer.ResponseWriter).Flush()
	}
	return count, err
}
