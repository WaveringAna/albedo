package daemon

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"albedo/cli/internal/daemon/protocol"
	"albedo/cli/internal/testwire"
)

func quotaConnection(t *testing.T, handler http.HandlerFunc) *Connection {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/server" && r.URL.Query().Get("include") != "quota_history" {
			_, _ = w.Write([]byte(testwire.Server))
			return
		}
		handler(w, r)
	}))
	t.Cleanup(server.Close)
	conn, err := Attach(t.Context(), ConnectionSnapshot{
		Port:    server.Listener.Addr().(*net.TCPAddr).Port,
		Token:   "token",
		Version: ProtocolVersion,
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(conn.HTTPClient().CloseIdleConnections)
	return conn
}

func observation(seq int64, account, provider, limit string) QuotaObservation {
	return QuotaObservation{
		Sequence:   seq,
		AccountID:  account,
		Provider:   provider,
		LimitID:    limit,
		Label:      "Primary",
		Status:     "ok",
		Source:     "poll",
		ObservedAt: time.UnixMilli(seq * 1000).UTC().Format(time.RFC3339),
	}
}

func TestGetQuotaTrailPagingAndFiltering(t *testing.T) {
	since := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	var requestCount atomic.Int32

	conn := quotaConnection(t, func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		if q.Get("include") != "quota_history" {
			t.Errorf("expected include=quota_history, got %q", q.Get("include"))
		}
		if q.Get("limit") != "200" {
			t.Errorf("expected limit=200, got %q", q.Get("limit"))
		}
		if q.Get("quota_provider") != "hyper" {
			t.Errorf("expected quota_provider=hyper, got %q", q.Get("quota_provider"))
		}
		if q.Get("quota_account") != "charm" {
			t.Errorf("expected quota_account=charm, got %q", q.Get("quota_account"))
		}
		if q.Get("quota_limit") != "primary" {
			t.Errorf("expected quota_limit=primary, got %q", q.Get("quota_limit"))
		}
		if q.Get("quota_since") != since.Format(time.RFC3339Nano) {
			t.Errorf("expected quota_since=%s, got %q", since.Format(time.RFC3339Nano), q.Get("quota_since"))
		}

		reqNum := requestCount.Add(1)
		var page protocol.QuotaPage
		switch reqNum {
		case 1:
			if q.Get("next") != "" {
				t.Errorf("expected empty next on page 1, got %q", q.Get("next"))
			}
			// Server returns newest-first: [seq 30, seq 20]
			nextCursor := "cursor-page-2"
			page = protocol.QuotaPage{
				Items: []QuotaObservation{
					observation(30, "charm", "hyper", "primary"),
					observation(20, "charm", "hyper", "primary"),
				},
				Next: &nextCursor,
			}
		case 2:
			if q.Get("next") != "cursor-page-2" {
				t.Errorf("expected next=cursor-page-2 on page 2, got %q", q.Get("next"))
			}
			// Page 2 returns seq 10, next is nil
			page = protocol.QuotaPage{
				Items: []QuotaObservation{
					observation(10, "charm", "hyper", "primary"),
				},
				Next: nil,
			}
		default:
			t.Fatalf("unexpected request number %d", reqNum)
		}

		var resp map[string]any
		_ = json.Unmarshal([]byte(testwire.Server), &resp)
		resp["quota_history"] = page
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	})

	results, err := GetQuotaTrail(t.Context(), conn, QuotaTrailQuery{
		Provider: "hyper",
		Account:  "charm",
		Limit:    "primary",
		Since:    since,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if int(requestCount.Load()) != 2 {
		t.Fatalf("expected 2 requests, made %d", requestCount.Load())
	}

	// Must be returned OLDEST FIRST: [seq 10, seq 20, seq 30]
	if len(results) != 3 {
		t.Fatalf("expected 3 results, got %d", len(results))
	}
	expectedSeqs := []int64{10, 20, 30}
	for i, exp := range expectedSeqs {
		if results[i].Sequence != exp {
			t.Errorf("result[%d] sequence: expected %d, got %d", i, exp, results[i].Sequence)
		}
	}
}

func TestGetQuotaTrailCapsAtFivePages(t *testing.T) {
	var requestCount atomic.Int32

	conn := quotaConnection(t, func(w http.ResponseWriter, r *http.Request) {
		reqNum := requestCount.Add(1)
		nextCursor := fmt.Sprintf("cursor-%d", reqNum+1)
		page := protocol.QuotaPage{
			Items: []QuotaObservation{
				observation(int64(100-reqNum), "acc", "prov", "lim"),
			},
			Next: &nextCursor,
		}

		var resp map[string]any
		_ = json.Unmarshal([]byte(testwire.Server), &resp)
		resp["quota_history"] = page
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	})

	results, err := GetQuotaTrail(t.Context(), conn, QuotaTrailQuery{
		Provider: "prov",
		Account:  "acc",
		Limit:    "lim",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Must stop at 5 pages
	if requestCount.Load() != 5 {
		t.Fatalf("expected exactly 5 requests, got %d", requestCount.Load())
	}
	if len(results) != 5 {
		t.Fatalf("expected 5 results, got %d", len(results))
	}
	// Oldest first: sequences were [99, 98, 97, 96, 95] returned newest first,
	// so reversed should be [95, 96, 97, 98, 99].
	expectedSeqs := []int64{95, 96, 97, 98, 99}
	for i, exp := range expectedSeqs {
		if results[i].Sequence != exp {
			t.Errorf("result[%d] sequence: expected %d, got %d", i, exp, results[i].Sequence)
		}
	}
}

func TestGetQuotaTrailWithoutSinceSendsNoBound(t *testing.T) {
	conn := quotaConnection(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Has("quota_since") {
			t.Errorf("a zero Since must not be sent, got quota_since=%q", r.URL.Query().Get("quota_since"))
		}
		var resp map[string]any
		_ = json.Unmarshal([]byte(testwire.Server), &resp)
		resp["quota_history"] = protocol.QuotaPage{Items: []QuotaObservation{}}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	})
	if _, err := GetQuotaTrail(t.Context(), conn, QuotaTrailQuery{Provider: "p", Account: "a", Limit: "l"}); err != nil {
		t.Fatal(err)
	}
}
