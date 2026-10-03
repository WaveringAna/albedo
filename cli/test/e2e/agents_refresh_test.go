//go:build unix

// The agents view must replace stale membership and previews after a lost feed.
package e2e

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/testwire"
	"albedo/cli/internal/tui"
	tea "charm.land/bubbletea/v2"
)

func TestTUIAgentsOverflowRefreshesMembershipAndPreviews(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	defer close(release)
	profile := providerRoute(t, func(request map[string]any) string {
		if lastUserText(request) == "held agent refresh turn" {
			close(entered)
			<-release
		}
		return echoReply(request)
	})
	root := daemonSession(t, newSession(t, t.TempDir()))
	create := func(name string) daemon.Session {
		t.Helper()
		child, err := daemon.CreateSession(t.Context(), conn(t), daemon.CreateSessionRequest{Kind: "child", ParentID: root.ID, Address: name, Name: name, Task: "finish child setup"})
		if err != nil {
			t.Fatal(err)
		}
		waitIdle(t, child.ID, profile, 1)
		return child
	}
	removed := create("removed")
	retained := create("old-name")
	waitIdle(t, root.ID, profile, 2)
	if _, err := daemon.NewChatClient(conn(t), root.ID).Send(t.Context(), "INITIAL_PREVIEW_SEED", nil); err != nil {
		t.Fatal(err)
	}
	waitIdle(t, root.ID, profile, 3)

	destination, err := url.Parse(conn(t).BaseURL())
	if err != nil {
		t.Fatal(err)
	}
	forward := httputil.NewSingleHostReverseProxy(destination)
	direct := forward.Director
	forward.Director = func(r *http.Request) { direct(r); r.Host = destination.Host }
	forward.FlushInterval = -1
	var streams atomic.Int32
	seedReady := make(chan struct{}, 1)
	fragments, gap := make(chan struct{}), make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/sessions" && r.Header.Get("Accept") == "text/event-stream" && streams.Add(1) == 1 {
			w.Header().Set("Content-Type", "text/event-stream")
			_, _ = fmt.Fprint(w, "data: {\"events\":[{\"type\":\"ready\",\"data\":{\"instance_id\":\"controlled-agent-stream\"}},{\"type\":\"reset\",\"data\":{\"reason\":\"initial\"}}]}\n\n")
			w.(http.Flusher).Flush()
			select {
			case <-fragments:
			case <-r.Context().Done():
				return
			}
			events, _ := json.Marshal(map[string]any{"events": []map[string]any{
				{"type": "activity", "data": map[string]any{"session_id": root.ID, "cursor": map[string]any{"generation": testwire.GenerationA, "sequence": 1}, "status": map[string]any{"phase": "running", "run_id": "old-run", "interrupt_requested": false, "blocking_reason": nil}, "current_progress": []map[string]any{{"call_id": "old-run:1:0", "tool_call_id": nil, "name": "python", "phase": "generating", "intent": "", "preview": map[string]any{"offset_scalars": 0, "text": "OLD_PARTIAL_CODE", "complete": false}}}, "activity": map[string]any{"lines": []map[string]any{{"kind": "assistant", "text": "OLD_PARTIAL_TEXT", "truncated": false}}, "output_scalars": 0, "output_utf8_bytes": 0, "observed_at": "2026-10-03T00:00:00Z", "latest_input": nil, "latest_answer": nil}}},
			}})
			_, _ = fmt.Fprintf(w, "data: %s\n\n", events)
			w.(http.Flusher).Flush()
			select {
			case <-gap:
				_, _ = fmt.Fprint(w, "data: {\"events\":[{\"type\":\"overflow\",\"data\":{\"reason\":\"subscriber_overflow\"}}]}\n\n")
				w.(http.Flusher).Flush()
			case <-r.Context().Done():
			}
			return
		}
		forward.ServeHTTP(w, r)
		if r.URL.Path == "/sessions/"+root.ID && r.URL.Query().Get("tail") != "" {
			select {
			case seedReady <- struct{}{}:
			default:
			}
		}
	}))
	t.Cleanup(server.Close)
	snapshot := conn(t).Snapshot()
	snapshot.Port = server.Listener.Addr().(*net.TCPAddr).Port
	connection, err := daemon.Attach(t.Context(), snapshot, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(connection.HTTPClient().CloseIdleConnections)
	driver := driveTUIWithConnection(t, &root, connection)
	driver.Update(tea.WindowSizeMsg{Width: 140, Height: 50})
	t.Cleanup(driver.App.Chat.Close)
	t.Cleanup(func() { driver.App.Agents.Close() })
	ctx, cancel := context.WithTimeout(t.Context(), 20*time.Second)
	defer cancel()
	inbox := make(chan tea.Msg, 64)
	streamMessages(ctx, driver.Update(tui.ChatOpenAgentsMsg{}), inbox)
	pump := func(condition func() bool) {
		t.Helper()
		for !condition() {
			select {
			case message := <-inbox:
				streamMessages(ctx, driver.Update(message), inbox)
			case <-ctx.Done():
				t.Fatalf("agent view did not recover:\n%s", driver.View())
			}
		}
	}
	pump(func() bool { return strings.Contains(driver.View(), "INITIAL_PREVIEW_SEED") })
	select {
	case <-seedReady:
	case <-ctx.Done():
		t.Fatal("initial preview request never completed")
	}
	close(fragments)
	pump(func() bool { return strings.Contains(driver.View(), "OLD_PARTIAL_CODE") })
	if !strings.Contains(driver.View(), "removed") || !strings.Contains(driver.View(), "old-name") {
		t.Fatalf("initial membership did not load:\n%s", driver.View())
	}
	if _, err := daemon.RenameSession(t.Context(), conn(t), retained.ID, "renamed", sessionCondition(t, conn(t), retained.ID).ETag); err != nil {
		t.Fatal(err)
	}
	if _, err := daemon.DeleteSession(t.Context(), conn(t), removed.ID, false, sessionCondition(t, conn(t), removed.ID)); err != nil {
		t.Fatal(err)
	}
	create("new-agent")
	if _, err := daemon.NewChatClient(conn(t), root.ID).Send(t.Context(), "held agent refresh turn", nil); err != nil {
		t.Fatal(err)
	}
	select {
	case <-entered:
	case <-ctx.Done():
		t.Fatal("held model turn did not start")
	}
	for _, character := range "draft survives refresh" {
		driver.Update(tea.KeyPressMsg{Code: character, Text: string(character)})
	}
	close(gap)
	pump(func() bool {
		view := driver.View()
		return strings.Contains(view, "renamed") && strings.Contains(view, "new-agent") && strings.Contains(view, "1 running") && !strings.Contains(view, "removed") && !strings.Contains(view, "old-name")
	})
	view := driver.View()
	if strings.Contains(view, "OLD_PARTIAL") || !strings.Contains(view, "draft survives refresh") {
		t.Fatalf("refresh retained stale fragments or discarded the input draft:\n%s", view)
	}
}
