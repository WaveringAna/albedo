// Controlled peers can return malformed reports that a healthy daemon cannot
// produce. These checks keep invalid sizes and missing arrays out of callers.
package daemon

import (
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const emptyStorageReport = `{"old_kernels":[],"old_backups":[],"db":{"sessions":[],"images":0,"free_pages":0,"page_size":0},"database":0,"wal":0,"kernels":0,"backups":0,"other":0,"recent_backups":0,"recent_backup_count":0}`

func TestStorageReportRejectsInvalidWireBeforeDelivery(t *testing.T) {
	for _, scenario := range []struct {
		name, body string
		status     int
		valid      bool
	}{
		{"empty", emptyStorageReport, 200, true},
		{"large integer", strings.Replace(emptyStorageReport, `"database":0`, `"database":9007199254740993`, 1), 200, true},
		{"null report", `null`, 200, false},
		{"missing database", strings.Replace(emptyStorageReport, `"database":0,`, "", 1), 200, false},
		{"null size", strings.Replace(emptyStorageReport, `"database":0`, `"database":null`, 1), 200, false},
		{"negative size", strings.Replace(emptyStorageReport, `"images":0`, `"images":-1`, 1), 200, false},
		{"fraction", strings.Replace(emptyStorageReport, `"database":0`, `"database":1.0000000000000001`, 1), 200, false},
		{"null files", strings.Replace(emptyStorageReport, `"old_kernels":[]`, `"old_kernels":null`, 1), 200, false},
		{"null file entry", strings.Replace(emptyStorageReport, `"old_kernels":[]`, `"old_kernels":[null]`, 1), 200, false},
		{"missing file bytes", strings.Replace(emptyStorageReport, `"old_kernels":[]`, `"old_kernels":[{"path":"kernel.state"}]`, 1), 200, false},
		{"empty path", strings.Replace(emptyStorageReport, `"old_backups":[]`, `"old_backups":[{"path":"","bytes":1}]`, 1), 200, false},
		{"null sessions", strings.Replace(emptyStorageReport, `"sessions":[]`, `"sessions":null`, 1), 200, false},
		{"null session", strings.Replace(emptyStorageReport, `"sessions":[]`, `"sessions":[null]`, 1), 200, false},
		{"empty session ID", strings.Replace(emptyStorageReport, `"sessions":[]`, `"sessions":[{"id":"","bytes":0}]`, 1), 200, false},
		{"negative session size", strings.Replace(emptyStorageReport, `"sessions":[]`, `"sessions":[{"id":"s","bytes":-1}]`, 1), 200, false},
		{"null count", strings.Replace(emptyStorageReport, `"recent_backup_count":0`, `"recent_backup_count":null`, 1), 200, false},
		{"fractional count", strings.Replace(emptyStorageReport, `"recent_backup_count":0`, `"recent_backup_count":0.5`, 1), 200, false},
		{"wrong status", emptyStorageReport, 202, false},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/health" {
					_, _ = w.Write([]byte(`{"ok":true,"version":2,"capabilities":["storage_report"]}`))
					return
				}
				if r.URL.Path != "/storage/report" || r.Method != http.MethodGet {
					t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
				}
				w.WriteHeader(scenario.status)
				_, _ = w.Write([]byte(scenario.body))
			}))
			defer server.Close()
			conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
			defer conn.HTTPClient().CloseIdleConnections()
			report, err := GetStorageReport(t.Context(), conn)
			if scenario.valid {
				if err != nil {
					t.Fatal(err)
				}
				if report.OldKernels == nil || report.OldBackups == nil || report.DB.Sessions == nil {
					t.Fatalf("missing empty arrays: %+v", report)
				}
				if scenario.name == "large integer" && report.Database != 9007199254740993 {
					t.Fatalf("rounded size: %d", report.Database)
				}
			} else {
				if err == nil {
					t.Fatalf("accepted invalid report: %+v", report)
				}
				if report.Database != 0 || report.OldKernels != nil || report.DB.Sessions != nil {
					t.Fatalf("returned partial report: %+v", report)
				}
				if scenario.status == 200 {
					if _, ok := errors.AsType[*ProtocolError](err); !ok {
						t.Fatalf("missing protocol failure: %v", err)
					}
				}
			}
		})
	}
}
