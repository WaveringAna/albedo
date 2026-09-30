// Error decoding must preserve status and structured causes even for malformed
// responses, which the real daemon E2E suite does not produce.
package daemon

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHTTPFailuresRetainIdentity(t *testing.T) {
	for _, tc := range []struct {
		name, body, code, workspace string
		status                      int
	}{
		{"workspace", `{"code":"workspace_missing","workspace":"/missing","error":"wording can change"}`, "workspace_missing", "/missing", 409},
		{"forbidden", `{"code":"forbidden","error":"access denied"}`, "forbidden", "", 403},
		{"unauthorized", `{"code":"unauthorized","error":"sign in again"}`, "unauthorized", "", 401},
		{"code only", `{"code":"busy"}`, "busy", "", 503},
		{"malformed", `<html>bad gateway</html>`, "", "", 502},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = io.WriteString(w, tc.body)
			}))
			defer server.Close()
			// This fixed peer has no discovery directory; authentication errors stay local.
			conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, "")
			_, requestErr := RequestMethod[any](context.Background(), conn, http.MethodGet, "/failure", nil)
			client := NewChatClient(ChatClientOptions{Conn: conn, AgentID: "session"})
			_, chatErr := client.GetStatus(context.Background())
			for _, err := range []error{requestErr, chatErr} {
				err = fmt.Errorf("request context: %w", err)
				var apiErr *APIError
				if !errors.As(err, &apiErr) || apiErr.StatusCode != tc.status || apiErr.Code != tc.code {
					t.Fatalf("lost HTTP failure identity: %v", err)
				}
				var workspaceErr *WorkspaceMissingError
				if tc.workspace != "" && (!errors.As(err, &workspaceErr) || workspaceErr.Workspace != tc.workspace) {
					t.Fatalf("lost workspace recovery information: %v", err)
				}
				if strings.Contains(err.Error(), "<html>") {
					t.Fatalf("exposed unstructured response body: %v", err)
				}
			}
		})
	}
}
