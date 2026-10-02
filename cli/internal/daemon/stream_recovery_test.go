// Hanging refusal bodies and failures after stream delivery require controlled
// peers; real daemon events cannot reliably force these transport boundaries.
package daemon

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

type streamCaller struct {
	start func(context.Context, *Connection, func() error) error
	name  string
}

func streamCallers() []streamCaller {
	return []streamCaller{
		{name: "agents", start: func(ctx context.Context, conn *Connection, deliver func() error) error {
			return StreamAgents(ctx, conn, func(_ []AgentEvent) error { return deliver() })
		}},
		{name: "chat", start: func(ctx context.Context, conn *Connection, deliver func() error) error {
			return NewChatClient(conn, "test").Stream(ctx, 0, func(event StreamEvent) error {
				if event.Type == EventText {
					return deliver()
				}
				return nil
			})
		}},
	}
}

func TestStreamAuthenticationRecoveryBeforeDelivery(t *testing.T) {
	for _, caller := range streamCallers() {
		t.Run(caller.name, func(t *testing.T) {
			for _, test := range []struct {
				name, token string
				marked      bool
				requests    int32
			}{
				{name: "changed credentials", token: "new", marked: true, requests: 2},
				{name: "unchanged credentials", token: "old", marked: true, requests: 1},
				{name: "unmarked refusal", token: "new", requests: 1},
			} {
				t.Run(test.name, func(t *testing.T) {
					var requests atomic.Int32
					var deliveries atomic.Int32
					server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
						if request.URL.Path == "/health" {
							_, _ = writer.Write([]byte(`{"ok":true,"version":2,"capabilities":["operation_receipts","session_stream_generation","agents_stream_overflow"]}`))
							return
						}
						if requests.Add(1) == 1 {
							if test.marked {
								writer.Header().Set("Albedo-Error-Code", "authentication_required")
							}
							writer.WriteHeader(http.StatusForbidden)
							if caller.name == "chat" {
								if test.marked {
									_, _ = writer.Write([]byte(`{"code":"authentication_required"}`))
								} else {
									_, _ = writer.Write([]byte(`{"error":"denied"}`))
								}
								return
							}
							// Agents inspect only the status and header. Closing the unfinished
							// body must cancel this handler without waiting for more bytes.
							writer.(http.Flusher).Flush()
							<-request.Context().Done()
							return
						}
						if request.Header.Get("Authorization") != "Bearer new" {
							t.Error("stream reused old credentials")
						}
						writer.Header().Set("Content-Type", "text/event-stream")
						_, _ = io.WriteString(writer, "data: {\"generation\":\"generation-a\",\"cursor\":1,\"events\":[{\"type\":\"reset\"},{\"type\":\"text\",\"session\":\"s\",\"text\":\"hello\"}]}\n\n")
					}))
					defer server.Close()

					snapshot := ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: test.token, Version: 2}
					replacement := snapshot
					snapshot.Token = "old"
					conn := NewConnection(snapshot, func(context.Context) (ConnectionSnapshot, error) { return replacement, nil })
					defer conn.HTTPClient().CloseIdleConnections()
					ctx, cancel := context.WithTimeout(context.Background(), time.Second)
					defer cancel()
					streamErr := caller.start(ctx, conn, func() error { deliveries.Add(1); return nil })
					if errors.Is(streamErr, context.DeadlineExceeded) {
						t.Fatalf("stream waited for unfinished refusal body: %v", streamErr)
					}
					if requests.Load() != test.requests {
						t.Fatalf("got %d requests, expected %d", requests.Load(), test.requests)
					}
					if test.requests == 2 {
						if streamErr != nil || deliveries.Load() != 1 {
							t.Fatalf("stream failed recovery: %v deliveries=%d", streamErr, deliveries.Load())
						}
					} else {
						failure, ok := errors.AsType[*APIError](streamErr)
						if !ok || failure.StatusCode != http.StatusForbidden || deliveries.Load() != 0 {
							t.Fatalf("refusal changed: %v deliveries=%d", streamErr, deliveries.Load())
						}
					}
				})
			}
		})
	}
}

func TestAcceptedStreamIsNeverReplayed(t *testing.T) {
	for _, caller := range streamCallers() {
		t.Run(caller.name, func(t *testing.T) {
			for _, failure := range []string{"truncated body", "callback error"} {
				t.Run(failure, func(t *testing.T) {
					var requests atomic.Int32
					var deliveries atomic.Int32
					callbackFailure := errors.New("consumer stopped")
					server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
						if request.URL.Path == "/health" {
							_, _ = writer.Write([]byte(`{"ok":true,"version":2,"capabilities":["operation_receipts","session_stream_generation","agents_stream_overflow"]}`))
							return
						}
						requests.Add(1)
						if failure == "truncated body" {
							writer.Header().Set("Content-Length", "1000")
						}
						writer.Header().Set("Content-Type", "text/event-stream")
						_, _ = io.WriteString(writer, "data: {\"generation\":\"generation-a\",\"cursor\":1,\"events\":[{\"type\":\"reset\"},{\"type\":\"text\",\"session\":\"s\",\"text\":\"hello\"}]}\n\n")
					}))
					defer server.Close()
					snapshot := ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "token", Version: 2}

					replacement := snapshot
					conn := NewConnection(snapshot, func(context.Context) (ConnectionSnapshot, error) { return replacement, nil })
					defer conn.HTTPClient().CloseIdleConnections()
					ctx, cancel := context.WithTimeout(context.Background(), time.Second)
					defer cancel()
					streamErr := caller.start(ctx, conn, func() error {
						deliveries.Add(1)
						if failure == "callback error" {
							return callbackFailure
						}
						return nil
					})
					if failure == "callback error" && !errors.Is(streamErr, callbackFailure) {
						t.Fatalf("callback failure lost: %v", streamErr)
					}
					if failure == "truncated body" && !errors.Is(streamErr, io.ErrUnexpectedEOF) {
						t.Fatalf("stream truncation lost: %v", streamErr)
					}
					if requests.Load() != 1 || deliveries.Load() != 1 {
						t.Fatalf("accepted stream replayed: requests=%d deliveries=%d", requests.Load(), deliveries.Load())
					}
				})
			}
		})
	}
}
