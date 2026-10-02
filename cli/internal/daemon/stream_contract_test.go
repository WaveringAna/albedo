// A daemon cannot emit deliberately malformed wire data. Controlled HTTP peers
// exercise batch atomicity and failure classification through the public stream API.
package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
)

func TestStreamRejectsMalformedBatchesWithoutLosingTheCursor(t *testing.T) {
	data, err := os.ReadFile("../../../test/fixtures/session_stream.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Malformed map[string]string `json:"malformed_batches"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Malformed) == 0 {
		t.Fatal("empty stream contract fixture")
	}
	for name, batch := range fixture.Malformed {
		t.Run(name, func(t *testing.T) {
			var requests atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "text/event-stream")
				switch requests.Add(1) {
				case 1:
					_, _ = io.WriteString(w, "data: "+`{"generation":"generation-a","cursor":7,"events":[{"type":"reset"},{"type":"text","text":"accepted"}]}`+"\n\n")
				case 2:
					_, _ = fmt.Fprintf(w, "data: %s\n\n", batch)
				default:
					if got := r.URL.Query().Get("after_seq"); got != "7" {
						t.Errorf("failed batch lost committed cursor: %s", got)
					}
					_, _ = io.WriteString(w, "data: "+`{"generation":"generation-a","cursor":8,"events":[{"type":"text","text":"replayed"}]}`+"\n\n")
				}
			}))
			defer server.Close()
			client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
			var delivered []string
			consume := func(event StreamEvent) error {
				if event.Type == EventReset {
					return nil
				}
				if event.Type != EventText {
					t.Errorf("unexpected event delivered: %+v", event)
				}
				delivered = append(delivered, event.Text)
				return nil
			}
			if err := client.Stream(t.Context(), 0, consume); err != nil {
				t.Fatal(err)
			}
			consumed := 0
			err := client.StreamWithProgress(t.Context(), 0, consume, func() { consumed++ })
			if consumed != 0 {
				t.Fatal("malformed batch reported consumption")
			}
			failure, ok := errors.AsType[*StreamError](err)
			if !ok || failure.Kind != StreamProtocol {
				t.Fatalf("malformed batch was not a protocol failure: %v", err)
			}
			if len(delivered) != 1 || delivered[0] != "accepted" {
				t.Fatalf("malformed batch partially delivered: %v", delivered)
			}
			if err := client.Stream(t.Context(), 0, consume); err != nil {
				t.Fatal(err)
			}
			if len(delivered) != 2 || delivered[1] != "replayed" || requests.Load() != 3 {
				t.Fatalf("replay lost events or retried internally: %v, requests=%d", delivered, requests.Load())
			}
		})
	}
}

func TestStreamIgnoresUnknownKindsAndCommitsTheirCursor(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		if requests.Add(1) == 1 {
			_, _ = io.WriteString(w, "data: "+`{"generation":"generation-a","cursor":12,"events":[{"type":"reset"},{"type":"future_output","text":"not assistant output","args":false}]}`+"\n\n")
		} else if got := r.URL.Query().Get("after_seq"); got != "12" {
			t.Errorf("ignored additive batch lost cursor: %s", got)
		}
	}))
	defer server.Close()
	client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
	consumed := 0
	for range 2 {
		if err := client.StreamWithProgress(t.Context(), 0, func(event StreamEvent) error {
			if event.Type != EventReset {
				t.Errorf("unknown event delivered: %+v", event)
			}
			return nil
		}, func() { consumed++ }); err != nil {
			t.Fatal(err)
		}
	}
	if consumed != 1 {
		t.Fatalf("ignored-only batch did not report consumption: %d", consumed)
	}
}

func TestStreamCallbackFailureRetainsCauseAndUncommittedCursor(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		n := requests.Add(1)
		if n == 1 {
			_, _ = io.WriteString(w, "data: "+`{"generation":"generation-a","cursor":7,"events":[{"type":"reset"}]}`+"\n\n")
			return
		}
		if n == 3 && (r.URL.Query().Get("after_seq") != "7" || r.URL.Query().Get("after_generation") != "generation-a") {
			t.Error("callback failure committed the batch cursor")
		}
		_, _ = io.WriteString(w, "data: "+`{"generation":"generation-b","cursor":8,"events":[{"type":"reset"},{"type":"text","text":"first"},{"type":"text","text":"second"}]}`+"\n\n")
	}))
	defer server.Close()
	client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
	if err := client.Stream(t.Context(), 0, func(StreamEvent) error { return nil }); err != nil {
		t.Fatal(err)
	}
	cause := errors.New("consumer stopped")
	var callbacks int
	err := client.Stream(t.Context(), 0, func(event StreamEvent) error {
		if event.Type == EventReset {
			return nil
		}
		callbacks++
		if callbacks == 2 {
			return cause
		}
		return nil
	})
	failure, ok := errors.AsType[*StreamError](err)
	if !ok || failure.Kind != StreamTerminal || !errors.Is(err, cause) {
		t.Fatalf("callback failure lost classification or cause: %v", err)
	}
	if requests.Load() != 2 || callbacks != 2 {
		t.Fatalf("callback failure changed delivery or retried: requests=%d, callbacks=%d", requests.Load(), callbacks)
	}
	if err := client.Stream(t.Context(), 0, func(StreamEvent) error { return nil }); err != nil {
		t.Fatal(err)
	}
}

func TestStreamClassifiesHTTPRefusalsWithoutRetryingThem(t *testing.T) {
	for _, test := range []struct {
		status int
		kind   StreamFailureKind
	}{
		{http.StatusNotFound, StreamTerminal}, {http.StatusForbidden, StreamTerminal},
		{http.StatusBadRequest, StreamTerminal}, {http.StatusRequestTimeout, StreamTransient},
		{http.StatusTooManyRequests, StreamTransient}, {http.StatusServiceUnavailable, StreamTransient},
	} {
		t.Run(http.StatusText(test.status), func(t *testing.T) {
			var requests atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				requests.Add(1)
				w.WriteHeader(test.status)
				_, _ = io.WriteString(w, `{"error":"stream unavailable"}`)
			}))
			defer server.Close()
			client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
			err := client.Stream(t.Context(), 0, func(StreamEvent) error {
				t.Error("HTTP refusal delivered an event")
				return nil
			})
			failure, ok := errors.AsType[*StreamError](err)
			api, apiOK := errors.AsType[*APIError](err)
			if !ok || failure.Kind != test.kind || !apiOK || api.StatusCode != test.status || requests.Load() != 1 {
				t.Fatalf("wrong refusal classification, cause, or retry: %v, requests=%d", err, requests.Load())
			}
		})
	}
}

func TestStreamRejectsNonSSESuccessResponses(t *testing.T) {
	for _, media := range []string{"", "text/html", "application/json"} {
		t.Run(media, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header()["Content-Type"] = nil
				if media != "" {
					w.Header().Set("Content-Type", media)
				}
				_, _ = io.WriteString(w, `{"error":"this is not a stream"}`)
			}))
			defer server.Close()
			client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
			err := client.Stream(t.Context(), 0, func(StreamEvent) error {
				t.Error("non-SSE response delivered an event")
				return nil
			})
			failure, ok := errors.AsType[*StreamError](err)
			if !ok || failure.Kind != StreamProtocol {
				t.Fatalf("wrong media type treated as recoverable EOF: %v", err)
			}
		})
	}
}

func TestStreamRecoveryRequiresResetBeforeDeliveringHistory(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		switch requests.Add(1) {
		case 1:
			_, _ = io.WriteString(w, "data: "+`{"generation":"generation-a","cursor":20,"events":[{"type":"reset"}]}`+"\n\n")
		case 2:
			_, _ = io.WriteString(w, "data: "+`{"generation":"generation-a","cursor":1,"events":[{"type":"text","text":"not durable reset"}]}`+"\n\n")
		case 3:
			_, _ = io.WriteString(w, "data: "+`{"generation":"generation-a","cursor":1,"events":[{"type":"reset"},{"type":"message","role":"assistant","text":"durable"}]}`+"\n\n")
		default:
			if r.URL.Query().Get("after_seq") != "1" {
				t.Error("validated reset failed to commit its cursor")
			}
		}
	}))
	defer server.Close()
	client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
	consume := func(StreamEvent) error { return nil }
	if err := client.Stream(t.Context(), 0, consume); err != nil {
		t.Fatal(err)
	}
	client.ResetStream()
	err := client.Stream(t.Context(), 0, func(StreamEvent) error {
		t.Error("non-reset recovery data escaped")
		return nil
	})
	failure, ok := errors.AsType[*StreamError](err)
	if !ok || failure.Kind != StreamProtocol {
		t.Fatalf("missing reset accepted: %v", err)
	}
	var replayed bool
	if err := client.Stream(t.Context(), 0, func(event StreamEvent) error {
		if event.Type == EventMessage {
			replayed = event.Replayed
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if !replayed {
		t.Fatal("reset snapshot was not marked as replayed history")
	}
	if err := client.Stream(t.Context(), 0, consume); err != nil {
		t.Fatal(err)
	}
}

func TestStreamClassifiesExplicitSSEFailures(t *testing.T) {
	for _, test := range []struct {
		name, payload string
		kind          StreamFailureKind
	}{
		{"reported failure", `{"error":"session removed"}`, StreamTerminal},
		{"malformed JSON", `{"error":`, StreamProtocol},
		{"malformed field", `{"error":false}`, StreamProtocol},
		{"missing reason", `{}`, StreamProtocol},
	} {
		t.Run(test.name, func(t *testing.T) {
			var requests atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				requests.Add(1)
				w.Header().Set("Content-Type", "text/event-stream")
				_, _ = fmt.Fprintf(w, "event: error\ndata: %s\n\n", test.payload)
			}))
			defer server.Close()
			client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
			err := client.Stream(t.Context(), 0, func(StreamEvent) error {
				t.Error("SSE failure became transcript output")
				return nil
			})
			failure, ok := errors.AsType[*StreamError](err)
			if !ok || failure.Kind != test.kind || requests.Load() != 1 {
				t.Fatalf("wrong explicit failure or automatic retry: %v, requests=%d", err, requests.Load())
			}
		})
	}
}

func TestStreamGenerationResetReplacesUnfinishedArguments(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		switch requests.Add(1) {
		case 1:
			if r.URL.Query().Has("after_seq") || r.URL.Query().Has("after_generation") {
				t.Error("initial subscription sent a cursor")
			}
			_, _ = io.WriteString(w, "data: "+`{"generation":"old","cursor":10,"events":[{"type":"reset"},{"type":"arguments_delta","callId":"same","name":"python","text":"{\"code\":\"old"}]}`+"\n\n")
		case 2:
			_, _ = io.WriteString(w, "data: "+`{"generation":"new","cursor":11,"events":[{"type":"text","text":"must stay hidden"}]}`+"\n\n")
		case 3:
			if r.URL.Query().Get("after_seq") != "10" || r.URL.Query().Get("after_generation") != "old" {
				t.Error("invalid generation change replaced the consumed pair")
			}
			_, _ = io.WriteString(w, "data: "+`{"generation":"new","cursor":1,"events":[{"type":"reset"},{"type":"arguments_delta","callId":"same","name":"python","text":"{\"code\":\"new()\"}"}]}`+"\n\n")
		default:
			if r.URL.Query().Get("after_seq") != "1" || r.URL.Query().Get("after_generation") != "new" {
				t.Error("successful reset failed to replace both cursor values")
			}
		}
	}))
	defer server.Close()
	client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
	var previews []string
	consume := func(event StreamEvent) error {
		if event.Type == EventText {
			t.Error("invalid generation events escaped")
		}
		if event.Progress != nil && event.Progress.Code != nil {
			previews = append(previews, event.Progress.Code.Text)
		}
		return nil
	}
	if err := client.Stream(t.Context(), 0, consume); err != nil {
		t.Fatal(err)
	}
	err := client.Stream(t.Context(), 0, consume)
	failure, ok := errors.AsType[*StreamError](err)
	if !ok || failure.Kind != StreamProtocol {
		t.Fatalf("generation change without reset accepted: %v", err)
	}
	for range 2 {
		if err := client.Stream(t.Context(), 0, consume); err != nil {
			t.Fatal(err)
		}
	}
	if len(previews) != 2 || previews[0] != "old" || previews[1] != "new()" {
		t.Fatalf("reset mixed old and new arguments: %q", previews)
	}
}

func TestInitialStreamRequiresLeadingReset(t *testing.T) {
	for _, events := range []string{`[]`, `[{"type":"text","text":"must stay hidden"}]`} {
		t.Run(events, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "text/event-stream")
				_, _ = fmt.Fprintf(w, "data: {\"generation\":\"new\",\"cursor\":0,\"events\":%s}\n\n", events)
			}))
			defer server.Close()
			client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
			err := client.Stream(t.Context(), 0, func(StreamEvent) error { t.Error("initial events escaped without reset"); return nil })
			failure, ok := errors.AsType[*StreamError](err)
			if !ok || failure.Kind != StreamProtocol {
				t.Fatalf("initial batch without reset accepted: %v", err)
			}
		})
	}
}

func TestStreamLoadsHistoryDespiteInvalidDisplayTraces(t *testing.T) {
	unicodeTrace, err := json.Marshal(ToolTrace{
		Activities: []ToolActivity{{Kind: "read", Target: strings.Repeat("界", 1000)}},
		Changes: []FileChange{
			{Kind: "diff", Path: strings.Repeat("界", 1000), Diff: strings.Repeat("🙂", 16000)},
			{Kind: "unavailable", Path: "binary", Reason: strings.Repeat("界", 1000)},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name      string
		trace     string
		wantTrace bool
	}{
		{"missing", "", false},
		{"null", "null", false},
		{"wrong type", `"unusable"`, false},
		{"wrong nested type", `{"activities":false}`, false},
		{"unknown activity", `{"activities":[{"kind":"unknown","target":"file"}]}`, false},
		{"oversized target", `{"activities":[{"kind":"read","target":"` + strings.Repeat("界", 1001) + `"}]}`, false},
		{"oversized diff", `{"changes":[{"kind":"diff","path":"file","diff":"` + strings.Repeat("🙂", 16001) + `"}]}`, false},
		{"negative line count", `{"changes":[{"kind":"diff","path":"file","added":-1}]}`, false},
		{"unicode at limits", string(unicodeTrace), true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			traceField := ""
			if tc.trace != "" {
				traceField = `,"trace":` + tc.trace
			}
			batch := `{"generation":"generation-a","cursor":12,"events":[{"type":"reset"},{"type":"tool","callId":"call","name":"python","args":"{}","result":"saved output"` + traceField + `},{"type":"text","text":"after tool"}]}`
			var requests atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "text/event-stream")
				if requests.Add(1) == 1 {
					_, _ = fmt.Fprintf(w, "data: %s\n\n", batch)
				} else if got := r.URL.Query().Get("after_seq"); got != "12" {
					t.Errorf("history batch lost cursor: %s", got)
				}
			}))
			defer server.Close()
			client := NewChatClient(NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil), "session")
			var events []StreamEvent
			consumed := 0
			for range 2 {
				if err := client.StreamWithProgress(t.Context(), 0, func(event StreamEvent) error {
					events = append(events, event)
					return nil
				}, func() { consumed++ }); err != nil {
					t.Fatal(err)
				}
			}
			if consumed != 1 || len(events) != 3 || events[1].Type != EventTool || events[1].ToolResult != "saved output" || events[2].Text != "after tool" {
				t.Fatalf("history did not load completely: consumed=%d events=%+v", consumed, events)
			}
			if got := events[1].ToolTrace; (got != nil) != tc.wantTrace {
				t.Fatalf("unexpected display trace: %+v", got)
			} else if tc.wantTrace {
				gotJSON, err := json.Marshal(got)
				if err != nil || string(gotJSON) != string(unicodeTrace) {
					t.Fatalf("unicode trace changed: %s, %v", gotJSON, err)
				}
			}
		})
	}
}
