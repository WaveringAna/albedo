// Stalled health checks and startup locks need controlled cancellation that
// daemon E2E cannot force reliably.
package daemon

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestEnsureHonorsCancellationDuringDiscoveryAndLockWait(t *testing.T) {
	for _, health := range []bool{false, true} {
		t.Run(fmt.Sprintf("stalled_health_%t", health), func(t *testing.T) {
			t.Setenv("ALBEDO_DAEMON", "")
			home := t.TempDir()
			if health {
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
				defer server.Close()
				writeDiscovery(t, home, ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "t", Version: 2})
			} else {
				if err := os.WriteFile(filepath.Join(home, "starting.lock"), fmt.Append(nil, os.Getpid()), 0600); err != nil {
					t.Fatal(err)
				}
			}
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
			defer cancel()
			started := time.Now()
			_, err := EnsureContext(ctx, home, "", nil)
			if !errors.Is(err, context.DeadlineExceeded) {
				t.Fatalf("deadline lost: %v", err)
			}
			if time.Since(started) > 300*time.Millisecond {
				t.Fatal("discovery or lock wait ignored caller deadline")
			}
		})
	}
}
