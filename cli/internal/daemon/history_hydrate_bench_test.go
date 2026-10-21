package daemon

import (
	"albedo/cli/internal/testwire"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
)

// referenceHistory serves the shape the audit measured: a history page whose
// parts over the inline budget are references, resolved by the batched content
// walk under the daemon's own per-piece and per-page byte budgets.
func referenceHistory(entries, oversized int) (http.HandlerFunc, *atomic.Int64) {
	var requests atomic.Int64
	const fieldBytes = 60_000
	const pieceBytes = 262_144
	const pageBytes = 400_000
	body := strings.Repeat("durable transcript content ", fieldBytes/len("durable transcript content "))
	walk := func(w http.ResponseWriter, names []string, cursor string) {
		index, offset := 0, 0
		if cursor != "" {
			index, _ = strconv.Atoi(strings.Split(cursor, ":")[0])
			offset, _ = strconv.Atoi(strings.Split(cursor, ":")[1])
		}
		parts, used := []string{}, 0
		for index < len(names) {
			end := min(len(body), offset+pieceBytes)
			part := fmt.Sprintf(`{"entry_id":%q,"field":"text","offset_bytes":%d,"encoding":"utf8","text":%q,"complete":%t}`,
				names[index], offset, body[offset:end], end == len(body))
			if used > 0 && used+len(part) > pageBytes {
				break
			}
			parts = append(parts, part)
			used += len(part)
			if end == len(body) {
				index, offset = index+1, 0
			} else {
				offset = end
			}
		}
		next := "null"
		if index < len(names) {
			next = strconv.Quote(strconv.Itoa(index) + ":" + strconv.Itoa(offset))
		}
		_, _ = fmt.Fprintf(w, `{"parts":[%s],"next":%s}`, strings.Join(parts, ","), next)
	}
	return func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		if r.URL.Path == "/sessions/s/history/content" {
			walk(w, strings.Split(r.URL.Query().Get("entries"), ","), r.URL.Query().Get("next"))
			return
		}
		items := make([]string, 0, entries)
		for i := 1; i <= entries; i++ {
			id := "e" + strconv.Itoa(i)
			content := fmt.Sprintf(`{"kind":"text","text":%q}`, "short reply "+strconv.Itoa(i))
			complete := true
			if i%3 == 0 && i <= oversized {
				content = fmt.Sprintf(`{"kind":"reference","reference":{"url":"/sessions/s/history/%s","field":"text","bytes":%d}}`, id, len(body))
				complete = false
			}
			items = append(items, fmt.Sprintf(`{"id":%q,"kind":"assistant","position":%d,"created_at":"2026-10-21T12:00:00Z","turn_type":"user","content_complete":%t,"content":[%s],"checkpoint_id":null,"input_id":null,"turn_id":null,"tool":null}`,
				id, i, complete, content))
		}
		_, _ = fmt.Fprintf(w, `{"items":[%s],"older":null,"newer":null,"high_water":%d}`, strings.Join(items, ","), entries)
	}, &requests
}

func benchmarkConnection(b *testing.B, handler http.HandlerFunc) *Connection {
	b.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/server" {
			_, _ = w.Write([]byte(testwire.Server))
			return
		}
		handler(w, r)
	}))
	b.Cleanup(server.Close)
	conn, err := Attach(b.Context(), ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "token", Version: ProtocolVersion}, nil)
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(conn.HTTPClient().CloseIdleConnections)
	return conn
}

// BenchmarkHistoryReferences measures opening one history page end to end:
// decoding, the batched content walk, and event projection. req/op follows the
// byte budget, not the number of references: twenty oversized entries cost the
// same few pages one oversized entry would.
func BenchmarkHistoryReferences(b *testing.B) {
	const entries = 100
	const oversized = 60
	handler, requests := referenceHistory(entries, oversized)
	conn := benchmarkConnection(b, handler)
	client := NewChatClient(conn, "s")
	b.ReportAllocs()
	b.ResetTimer()
	total := 0
	for b.Loop() {
		before := requests.Load()
		page, err := client.History(b.Context(), 0, entries)
		if err != nil {
			b.Fatal(err)
		}
		if len(page.Events) < entries {
			b.Fatalf("history lost entries: %d", len(page.Events))
		}
		total += int(requests.Load() - before)
	}
	b.ReportMetric(float64(total)/float64(b.N), "req/op")
}
