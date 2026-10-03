// Controlled peers exercise delivery and failure behavior the real daemon cannot force deterministically.
package daemon

import (
	"io"
	"net/http"
	"sync/atomic"
	"testing"
)

func TestConditionalMutationUsesObservedValidatorAndNeverRetriesConflict(t *testing.T) {
	var requests atomic.Int32
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		if r.Method != "PATCH" || r.URL.String() != "/sessions/s?view=configuration" || r.Header.Get("If-Match") != "\"seen\"" || r.Header.Get("Content-Type") != "application/merge-patch+json" {
			t.Errorf("wrong conditional mutation: %s %s %v", r.Method, r.URL, r.Header)
		}
		w.WriteHeader(412)
		_, _ = io.WriteString(w, `{"type":"about:blank","title":"Changed","status":412,"code":"precondition_failed","detail":"Refresh first"}`)
	})
	if _, err := RenameSession(t.Context(), conn, "s", "name", ""); err == nil || requests.Load() != 0 {
		t.Fatal("unobserved mutation dispatched")
	}
	if _, err := RenameSession(t.Context(), conn, "s", "name", "\"seen\""); err == nil || requests.Load() != 1 {
		t.Fatalf("conditional conflict retried: %v count=%d", err, requests.Load())
	}
}
