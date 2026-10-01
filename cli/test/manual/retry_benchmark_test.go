// These opt-in benchmarks isolate client recovery costs from daemon execution.
// The same bounded local HTTP fixture counts requests and mutation effects in
// every revision; real admission and persistence are exercised by E2E scenarios.
package manual

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"sync/atomic"
	"testing"

	"albedo/cli/internal/daemon"
)

func BenchmarkOperation(b *testing.B) {
	for _, scenario := range []string{"healthy-read", "healthy-mutation", "read-recovery", "auth-recovery", "lost-mutation-ack"} {
		b.Run(scenario, func(b *testing.B) { benchmarkOperation(b, scenario) })
	}
}

func benchmarkOperation(b *testing.B, scenario string) {
	var requests, effects, healthProbes atomic.Int64
	var drop atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/health" {
			healthProbes.Add(1)
			_, _ = io.WriteString(writer, `{"version":2}`)
			return
		}
		requests.Add(1)
		if request.Header.Get("Authorization") != "Bearer fixture-token" {
			writer.Header().Set("Albedo-Error-Code", "authentication_required")
			writer.WriteHeader(http.StatusForbidden)
			_, _ = io.WriteString(writer, `{"error":"forbidden","code":"authentication_required"}`)
			return
		}
		if request.Method == http.MethodPost {
			effects.Add(1)
		}
		_, _ = io.Copy(io.Discard, request.Body)
		if drop.Swap(false) {
			socket, _, err := writer.(http.Hijacker).Hijack()
			if err == nil {
				_ = socket.Close()
			}
			return
		}
		if scenario == "read-recovery" {
			writer.Header().Set("Connection", "close")
		}
		_, _ = io.WriteString(writer, `{"ok":true}`)
	}))
	defer server.Close()
	snapshot := daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "fixture-token", Version: 2}
	home := b.TempDir()
	encoded, err := json.Marshal(snapshot)
	if err != nil {
		b.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "daemon.json"), encoded, 0o600); err != nil {
		b.Fatal(err)
	}
	connection := daemon.NewConnection(snapshot, home)
	defer connection.HTTPClient().CloseIdleConnections()
	method := http.MethodPost
	var payload any = map[string]string{"text": "bounded fixture mutation"}
	read := scenario == "healthy-read" || scenario == "read-recovery"
	if read {
		method, payload = http.MethodGet, nil
	}
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		if scenario == "auth-recovery" {
			stale := snapshot
			stale.Token = "expired-token"
			connection.Update(daemon.NewConnection(stale, home))
		}
		drop.Store(scenario == "read-recovery" || scenario == "lost-mutation-ack")
		err := benchmarkRequest(context.Background(), connection, method, payload, read)
		if scenario != "lost-mutation-ack" && err != nil {
			b.Fatal(err)
		}
		runtime.KeepAlive(err)
	}
	b.StopTimer()
	b.ReportMetric(float64(requests.Load())/float64(b.N), "requests/op")
	b.ReportMetric(float64(effects.Load())/float64(b.N), "effects/op")
	b.ReportMetric(float64(healthProbes.Load())/float64(b.N), "health-probes/op")
}
