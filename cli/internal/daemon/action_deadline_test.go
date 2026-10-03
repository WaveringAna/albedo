// Controlled peers exercise delivery and failure behavior the real daemon cannot force deterministically.
package daemon

import (
	"context"
	"fmt"
	"net/http"
	"testing"
	"time"
)

func TestCompletedActionsRetainTheirDeadlineAndCallerCancellation(t *testing.T) {
	cases := []struct {
		name, path, body string
		status           int
		long             bool
		invoke           func(context.Context, *Connection) error
	}{
		{"reload", "/sessions/s/reload", `{"session":{"state":"applied","loaded_revision":"loaded-current","restart_required":false,"warnings":[],"failure":null},"models":[],"cache_policy":{"state":"refreshed","failure":null}}`, 200, true, func(ctx context.Context, conn *Connection) error {
			_, err := ReloadSession(ctx, conn, "s", ReloadRequest{Target: "both"})
			return err
		}},
		{"upgrade", "/sessions/s/kernel/upgrade", `{"old_build":null,"new_build":null,"state":"unchanged","stopped_jobs":[],"warnings":[],"failure":null,"old_kernel_id":null,"new_kernel_id":null}`, 200, true, func(ctx context.Context, conn *Connection) error { _, err := UpgradeKernel(ctx, conn, "s"); return err }},
		{"compaction", "/sessions/s/compaction", `{"selection_applied":false,"effective_strategy":null,"state":"unchanged","observation":null,"failure":null}`, 200, true, func(ctx context.Context, conn *Connection) error {
			_, err := CompactSession(ctx, conn, "s", "")
			return err
		}},
		{"shutdown", "/server/shutdown", `{"instance_id":"instance","state":"draining"}`, 202, false, StopDaemon},
	}
	for _, test := range cases {
		for _, shorter := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/shorter=%t", test.name, shorter), func(t *testing.T) {
				ctx := t.Context()
				if shorter {
					var cancel context.CancelFunc
					ctx, cancel = context.WithTimeout(ctx, time.Second)
					defer cancel()
				}
				transport := captureTransport{entered: make(chan *http.Request), release: make(chan struct{}), body: test.body, status: test.status}
				conn := NewConnection(ConnectionSnapshot{Port: 12345, Token: "token", Version: ProtocolVersion, InstanceID: "instance"}, nil)
				conn.HTTPClient().Transport = transport
				finished := make(chan error, 1)
				go func() { finished <- test.invoke(ctx, conn) }()
				request := <-transport.entered
				deadline, ok := request.Context().Deadline()
				close(transport.release)
				if err := <-finished; err != nil {
					t.Fatal(err)
				}
				if !ok || request.URL.Path != test.path || request.GetBody != nil {
					t.Fatalf("wrong action transport contract: %s deadline=%t replay=%t", request.URL.Path, ok, request.GetBody != nil)
				}
				if shorter {
					parentDeadline, _ := ctx.Deadline()
					if !deadline.Equal(parentDeadline) {
						t.Fatal("action extended the caller deadline")
					}
				} else if remaining := time.Until(deadline); test.long && remaining < 185*time.Second || !test.long && remaining > 20*time.Second {
					t.Fatalf("action used wrong deadline budget: %s", remaining)
				}
			})
		}
	}
}
