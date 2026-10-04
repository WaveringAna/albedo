// Request pointers and omission can change replay intent after preparation.
// Controlled acknowledgement loss exercises the public API's saved request.
package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

func TestSubmissionRecoversRejectedInputWithoutReplay(t *testing.T) {
	var admissions atomic.Int64
	var lookups atomic.Int64
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.URL.Path, "/sessions/s/inputs/")
		if id == r.URL.Path {
			t.Errorf("unexpected input resource %s", r.URL)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		switch r.Method {
		case http.MethodPut:
			admissions.Add(1)
			connection, _, err := w.(http.Hijacker).Hijack()
			if err != nil {
				t.Error(err)
				return
			}
			_ = connection.Close()
		case http.MethodGet:
			lookups.Add(1)
			input := canonicalInput("s", id, "message", "pending")
			input["admission"], input["http_status"] = "rejected", http.StatusUnprocessableEntity
			input["accepted_at"], input["acceptance_order"], input["delivery"] = nil, nil, nil
			input["problem"] = map[string]any{"type": "about:blank", "title": "Input refused", "status": http.StatusUnprocessableEntity, "code": "invalid_input", "detail": ""}
			_ = json.NewEncoder(w).Encode(input)
		default:
			t.Errorf("unexpected input method %s", r.Method)
			w.WriteHeader(http.StatusMethodNotAllowed)
		}
	})
	text := "rejected once"
	handle, err := NewSubmission("s", SubmissionRequest{Content: &text})
	if err != nil {
		t.Fatal(err)
	}
	_, err = SubmitOperation(t.Context(), conn, handle)
	problem, ok := errors.AsType[*APIError](err)
	if !ok || problem.StatusCode != http.StatusUnprocessableEntity || problem.Code != "invalid_input" || problem.Message != "Input refused" {
		t.Fatalf("lost rejection was not recovered: %v", err)
	}
	if admissions.Load() != 1 || lookups.Load() != 1 {
		t.Fatalf("authoritative rejection replayed: admissions=%d lookups=%d", admissions.Load(), lookups.Load())
	}
}

func TestSubmissionFreezesContentAndOmissionAcrossLostAcknowledgement(t *testing.T) {
	for _, continuation := range []bool{false, true} {
		t.Run(fmt.Sprint(continuation), func(t *testing.T) {
			var mu sync.Mutex
			var bodies []string
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodGet {
					w.WriteHeader(404)
					_, _ = fmt.Fprint(w, `{"type":"about:blank","title":"Input not found","status":404,"code":"input_unknown","detail":"not found"}`)
					return
				}
				body, _ := io.ReadAll(r.Body)
				mu.Lock()
				bodies = append(bodies, string(body))
				first := len(bodies) == 1
				mu.Unlock()
				if first {
					connection, _, err := w.(http.Hijacker).Hijack()
					if err != nil {
						t.Error(err)
						return
					}
					_ = connection.Close()
					return
				}
				var fields map[string]string
				_ = json.Unmarshal(body, &fields)
				id := strings.TrimPrefix(r.URL.Path, "/sessions/s/inputs/")
				if r.Method != http.MethodPut || id == r.URL.Path {
					t.Errorf("wrong admission resource %s %s", r.Method, r.URL)
				}
				w.WriteHeader(202)
				_ = json.NewEncoder(w).Encode(canonicalInput("s", id, fields["kind"], "pending"))
			}))
			defer server.Close()
			conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "token"}, nil)
			content := ""
			request := SubmissionRequest{Content: &content, Type: "user"}
			if continuation {
				request.Content = nil
				request.Type = "continue"
			}
			handle, err := NewSubmission("s", request)
			if err != nil {
				t.Fatal(err)
			}
			content = "changed after preparation"
			_, err = SubmitOperation(t.Context(), conn, handle)
			if err != nil {
				t.Fatal(err)
			}
			mu.Lock()
			defer mu.Unlock()
			if len(bodies) != 2 || bodies[0] != bodies[1] {
				t.Fatalf("recovery changed saved request: %v", bodies)
			}
			var fields map[string]json.RawMessage
			if err = json.Unmarshal([]byte(bodies[0]), &fields); err != nil {
				t.Fatal(err)
			}
			if continuation {
				if _, present := fields["text"]; present {
					t.Fatalf("continuation gained content: %s", bodies[0])
				}
			} else if string(fields["text"]) != `""` {
				t.Fatalf("prepared empty content changed: %s", bodies[0])
			}
			if _, present := fields["submissionId"]; present {
				t.Fatalf("input identity duplicated in body: %s", bodies[0])
			}
		})
	}
}
