// Controlled cancellation and malformed wire batches cannot be forced reliably
// through a scripted provider; these tests exercise the public transport boundaries.
package daemon

import (
	"context"
	"encoding/json"
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

func TestDiscoveryAndLauncherWaitHonorCancellation(t *testing.T) {
	for _, health := range []bool{false, true} {
		t.Run(fmt.Sprintf("stalled_health_%t", health), func(t *testing.T) {
			home := t.TempDir()
			var operation func(context.Context) error
			if health {
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
				defer server.Close()
				writeDiscovery(t, home, ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Pid: os.Getpid(), Token: "t", Version: ProtocolVersion})
				operation = func(ctx context.Context) error { _, err := Discover(ctx, home); return err }
			} else {
				if processAlive(0) {
					t.Skip("advisory locking requires Unix")
				}
				executable := filepath.Join(t.TempDir(), "unused-daemon")
				if err := os.WriteFile(executable, []byte("#!/bin/sh\nexit 99\n"), 0700); err != nil {
					t.Fatal(err)
				}
				t.Setenv("ALBEDO_DAEMON", executable)
				lock, err := acquireLauncher(t.Context(), home)
				if err != nil {
					t.Fatal(err)
				}
				defer lock.Close()
				operation = func(ctx context.Context) error { _, err := Launch(ctx, LocalOptions{HomeDir: home}); return err }
			}
			ctx, cancel := context.WithTimeout(t.Context(), 30*time.Millisecond)
			defer cancel()
			started := time.Now()
			if err := operation(ctx); !errors.Is(err, context.DeadlineExceeded) {
				t.Fatalf("deadline lost: %v", err)
			}
			if time.Since(started) > 300*time.Millisecond {
				t.Fatal("discovery or launcher wait ignored caller deadline")
			}
		})
	}
}

func TestAgentEventsValidateNullableSendersAndBooleanFields(t *testing.T) {
	event, err := decodeAgentEvent(json.RawMessage(`{"type":"mail","data":{"mail_id":"m","sender_session_id":null,"sender_label":null,"receiver_session_id":"s","kind":"message","bytes":2}}`))
	if err != nil || event == nil || event.To != "s" {
		t.Fatalf("nullable bus sender rejected: %v", err)
	}
	if _, err := decodeAgentEvent(json.RawMessage(`{"type":"invalidate","data":{"urls":[],"session_ids":["s"],"scope_dirty":"false"}}`)); err == nil {
		t.Fatal("malformed bus boolean accepted")
	}
}

// Presence and null differ even when Go would decode both as the same zero.
// A controlled peer can violate these contracts at every nested boundary.
func TestSessionReadValidatesRequiredAndNullableMembers(t *testing.T) {
	for _, scenario := range []struct {
		name   string
		change func(map[string]any)
		valid  bool
	}{
		{"required nullable omitted", func(session map[string]any) { delete(session, "effort") }, false},
		{"nullable retained", func(session map[string]any) { session["effort"] = nil }, true},
		{"nested required omitted", func(session map[string]any) {
			delete(session["kernel"].(map[string]any), "live_job_count")
		}, false},
		{"nested nullable retained", func(session map[string]any) {
			session["kernel"].(map[string]any)["live_job_count"] = nil
		}, true},
		{"null scalar", func(session map[string]any) {
			session["status"].(map[string]any)["interrupt_requested"] = nil
		}, false},
		{"null array", func(session map[string]any) { session["glances"] = nil }, false},
		{"null object", func(session map[string]any) { session["preferences"] = nil }, false},
		{"optional progress preview omitted", func(session map[string]any) {
			progress := canonicalProgress("call")
			delete(progress, "preview")
			session["current_progress"] = []any{progress}
		}, true},
		{"optional progress preview null", func(session map[string]any) {
			progress := canonicalProgress("call")
			progress["preview"] = nil
			session["current_progress"] = []any{progress}
		}, false},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			session := canonicalSession("s", generationA, 0)
			scenario.change(session)
			conn := controlledConnection(t, func(w http.ResponseWriter, request *http.Request) {
				if request.URL.RequestURI() != "/sessions/s?tail=0" {
					t.Errorf("unexpected session read %s", request.URL)
				}
				_ = json.NewEncoder(w).Encode(session)
			})
			captured, err := GetSession(t.Context(), conn, "s")
			if scenario.valid {
				if err != nil || captured.ID != "s" {
					t.Fatalf("nullable native fact rejected: %+v, %v", captured, err)
				}
			} else if _, ok := errors.AsType[*ProtocolError](err); !ok {
				t.Fatalf("malformed required member accepted: %v", err)
			}
		})
	}
}
