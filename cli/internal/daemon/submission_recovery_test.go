// Request pointers and omission can change replay intent after preparation.
// Controlled acknowledgement loss exercises the public API's saved request.
package daemon

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

func TestSubmissionFreezesContentAndOmissionAcrossLostAcknowledgement(t *testing.T) {
	for _, continuation := range []bool{false, true} {
		t.Run(fmt.Sprint(continuation), func(t *testing.T) {
			var mu sync.Mutex
			var bodies []string
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodGet {
					w.WriteHeader(404)
					_, _ = fmt.Fprint(w, `{"code":"operation_unknown","error":"not found"}`)
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
				var request struct {
					OperationID string `json:"operationId"`
				}
				_ = json.Unmarshal(body, &request)
				w.WriteHeader(202)
				_, _ = fmt.Fprintf(w, `{"ok":true,"queued":false,"operationId":%q}`, request.OperationID)
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
				if _, present := fields["content"]; present {
					t.Fatalf("continuation gained content: %s", bodies[0])
				}
			} else if string(fields["content"]) != `""` {
				t.Fatalf("prepared empty content changed: %s", bodies[0])
			}
			if string(fields["operationId"]) != fmt.Sprintf("%q", handle.ID()) || string(fields["submissionId"]) != string(fields["operationId"]) {
				t.Fatalf("recovery lost submission identity: %s", bodies[0])
			}
		})
	}
}
