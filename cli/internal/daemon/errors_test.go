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
		name, body, code string
		status           int
	}{
		{"workspace", `{"type":"about:blank","title":"Workspace unavailable","status":503,"code":"workspace_unavailable","detail":"wording can change"}`, "workspace_unavailable", 503},
		{"forbidden", `{"type":"about:blank","title":"Forbidden","status":403,"code":"forbidden","detail":"access denied"}`, "forbidden", 403},
		{"unauthorized", `{"type":"about:blank","title":"Unauthorized","status":401,"code":"unauthorized","detail":"sign in again"}`, "unauthorized", 401},
		{"code only", `{"code":"busy"}`, "busy", 503},
		{"malformed", `<html>bad gateway</html>`, "", 502},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = io.WriteString(w, tc.body)
			}))
			defer server.Close()
			// This fixed peer has no discovery directory; authentication errors stay local.
			conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
			_, requestErr := requestBytes(context.Background(), conn, operation{Name: "read failure", Method: http.MethodGet, Path: "/failure", Policy: readRecovery}, responseLimits{bodyBytes: 50 * 1024 * 1024, errorBytes: 64 * 1024})
			client := NewChatClient(conn, "session")
			_, chatErr := client.GetStatus(context.Background())
			for _, err := range []error{requestErr, chatErr} {
				err = fmt.Errorf("request context: %w", err)
				var apiErr *APIError
				if !errors.As(err, &apiErr) || apiErr.StatusCode != tc.status || apiErr.Code != tc.code {
					t.Fatalf("lost HTTP failure identity: %v", err)
				}
				if strings.Contains(err.Error(), "<html>") {
					t.Fatalf("exposed unstructured response body: %v", err)
				}
			}
		})
	}
}
