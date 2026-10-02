// Conflicting patches must fail before dispatch. A real daemon cannot show
// whether the adapter refused a request before sending it.
package daemon

import (
	"albedo/cli/internal/config"
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

func TestInvalidSettingsPatchesNeverDispatch(t *testing.T) {
	var requests atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		fmt.Fprint(w, `{"reloaded":"session","message":"saved"}`)
	}))
	defer server.Close()
	conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "token"}, nil)
	serverConfig := &config.MCPServer{Type: "http", URL: "http://localhost/mcp"}
	for _, test := range []struct {
		name  string
		apply func(context.Context) error
	}{
		{"replace and remove bearer", func(ctx context.Context) error {
			_, err := SaveMCP(ctx, conn, "s", MCPUpdateRequest{Name: "server", Server: serverConfig, Secrets: MCPSecretsPatch{BearerToken: new("replacement"), RemoveBearerToken: true}})
			return err
		}},
		{"replace and clear headers", func(ctx context.Context) error {
			_, err := SaveMCP(ctx, conn, "s", MCPUpdateRequest{Name: "server", Server: serverConfig, Secrets: MCPSecretsPatch{Headers: map[string]*string{}, ClearHeaders: true}})
			return err
		}},
		{"replace and clear environment", func(ctx context.Context) error {
			_, err := SaveMCP(ctx, conn, "s", MCPUpdateRequest{Name: "server", Server: serverConfig, Secrets: MCPSecretsPatch{Env: map[string]*string{}, ClearEnv: true}})
			return err
		}},
		{"pin in global preferences", func(ctx context.Context) error {
			_, err := PatchUI(ctx, conn, UIPreferencesPatch{Pinned: new(false)})
			return err
		}},
		{"global tools in session preferences", func(ctx context.Context) error {
			_, err := PatchSessionUI(ctx, conn, "s", UIPreferencesPatch{Tools: new(false)})
			return err
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			if err := test.apply(t.Context()); err == nil {
				t.Fatal("invalid patch was accepted")
			}
			if requests.Load() != 0 {
				t.Fatal("invalid patch reached the daemon")
			}
		})
	}
}
