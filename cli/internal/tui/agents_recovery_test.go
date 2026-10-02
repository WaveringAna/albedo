// A controlled peer holds snapshots across stream updates and delivers replies
// late. Real provider timing cannot reliably create these response orderings.
package tui

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestAgentsRefreshDiscardsDirtyAndPreviousSubscriptionReplies(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	feeds := []chan string{make(chan string, 4), make(chan string, 4), make(chan string, 4)}
	failureRelease, dirtyRelease := make(chan struct{}), make(chan struct{})
	var streams, snapshots, seeds atomic.Int32
	changed := make(chan struct{}, 16)
	notify := func() {
		select {
		case changed <- struct{}{}:
		default:
		}
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/agents/stream":
			number := streams.Add(1)
			notify()
			if number > int32(len(feeds)) {
				t.Error("unexpected extra subscription")
				return
			}
			w.Header().Set("Content-Type", "text/event-stream")
			_, _ = fmt.Fprint(w, "data: {\"events\":[]}\n\n")
			w.(http.Flusher).Flush()
			for {
				select {
				case batch := <-feeds[number-1]:
					_, _ = fmt.Fprintf(w, "data: %s\n\n", batch)
					w.(http.Flusher).Flush()
					if strings.Contains(batch, "overflow") {
						return
					}
				case <-r.Context().Done():
					return
				case <-ctx.Done():
					return
				}
			}
		case r.URL.Path == "/agents":
			number := snapshots.Add(1)
			notify()
			if streams.Load() == 0 {
				t.Error("snapshot preceded subscription readiness")
			}
			name := "LIVE_TREE"
			switch number {
			case 1:
				select {
				case <-failureRelease:
				case <-ctx.Done():
					return
				}
				w.WriteHeader(http.StatusServiceUnavailable)
				_, _ = fmt.Fprint(w, `{"error":"snapshot refused"}`)
				return
			case 2:
				select {
				case <-dirtyRelease:
				case <-ctx.Done():
					return
				}
				name = "DIRTY_TREE"
			case 4:
				name = "OLD_SUBSCRIPTION_TREE"
			case 5:
				name = "FINAL_TREE"
			}
			_, _ = fmt.Fprintf(w, `{"root":"lead","nodes":[{"session":{"id":"lead","model":"test","title":"","workspace":"","provider":"fixture","protocol":"responses","effort":null,"last_assistant_at":null},"parent":null,"address":null,"name":%q,"depth":0,"running":false,"closed":false}]}`, name)
		case strings.HasSuffix(r.URL.Path, "/preview"):
			preview := "OLD_SUBSCRIPTION_SEED"
			if seeds.Add(1) > 1 {
				preview = "FINAL_SEED"
			}
			_, _ = fmt.Fprintf(w, `{"total":1,"items":[{"type":"assistant","preview":%q}]}`, preview)
		default:
			t.Errorf("unexpected request: %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()
	defer cancel()
	connection := daemon.NewConnection(daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
	defer connection.HTTPClient().CloseIdleConnections()
	model := NewAgentsViewModel(connection, "lead")
	defer func() { model.Close() }()
	model.SetSize(120, 30)
	inbox := make(chan tea.Msg, 16)
	var run func(tea.Cmd)
	run = func(cmd tea.Cmd) {
		if cmd == nil {
			return
		}
		go func() {
			message := cmd()
			if batch, ok := message.(tea.BatchMsg); ok {
				for _, child := range batch {
					run(child)
				}
				return
			}
			switch message.(type) {
			case agentsSnapshotMsg, agentsEventsMsg, agentsStreamClosedMsg, agentsSnapshotRetryMsg, agentsSeedMsg, agentsSeedErrMsg:
				select {
				case inbox <- message:
				case <-ctx.Done():
				}
			}
		}()
	}
	update := func(message tea.Msg) { var cmd tea.Cmd; model, cmd = model.Update(message); run(cmd) }
	view := func() string { return ansi.Strip(model.View()) }
	pump := func(done func() bool) {
		t.Helper()
		for !done() {
			select {
			case message := <-inbox:
				update(message)
			case <-changed:
			case <-ctx.Done():
				t.Fatalf("refresh did not settle:\n%s", view())
			}
		}
	}
	take := func(matches func(tea.Msg) bool) tea.Msg {
		t.Helper()
		for {
			select {
			case message := <-inbox:
				if matches(message) {
					return message
				}
				update(message)
			case <-ctx.Done():
				t.Fatalf("expected response never arrived:\n%s", view())
				return nil
			}
		}
	}
	run(model.Init())
	pump(func() bool { return snapshots.Load() == 1 })
	feeds[0] <- `{"events":[{"type":"spawn","session":"lead","parent":"lead","name":"first","model":"test","depth":0}]}`
	// The event must be consumed before releasing the failed snapshot.
	takeEvent := take(func(message tea.Msg) bool { batch, ok := message.(agentsEventsMsg); return ok && len(batch.Events) > 0 })
	update(takeEvent)
	close(failureRelease)
	pump(func() bool { return strings.Contains(view(), "snapshot refused") })
	pump(func() bool { return snapshots.Load() == 2 })
	feeds[0] <- `{"events":[{"type":"renamed","session":"lead","name":"renamed-during-fetch"}]}`
	update(take(func(message tea.Msg) bool { batch, ok := message.(agentsEventsMsg); return ok && len(batch.Events) > 0 }))
	close(dirtyRelease)
	dirty := take(func(message tea.Msg) bool {
		snapshot, ok := message.(agentsSnapshotMsg)
		return ok && snapshot.Err == nil
	})
	update(dirty)
	if strings.Contains(view(), "DIRTY_TREE") {
		t.Fatal("dirty snapshot replaced the live graph")
	}
	pump(func() bool { return strings.Contains(view(), "LIVE_TREE") })
	oldSeed := take(func(message tea.Msg) bool { _, ok := message.(agentsSeedMsg); return ok })
	feeds[0] <- `{"events":[{"type":"overflow"}]}`
	oldSnapshot := take(func(message tea.Msg) bool {
		snapshot, ok := message.(agentsSnapshotMsg)
		return ok && snapshot.Err == nil
	})
	feeds[1] <- `{"events":[{"type":"overflow"}]}`
	pump(func() bool { return strings.Contains(view(), "FINAL_SEED") })
	update(oldSnapshot)
	update(oldSeed)
	if strings.Contains(view(), "OLD_SUBSCRIPTION") || !strings.Contains(view(), "FINAL_TREE") || !strings.Contains(view(), "FINAL_SEED") {
		t.Fatalf("late success restored stale membership or history:\n%s", view())
	}
	if streams.Load() != 3 || snapshots.Load() != 5 {
		t.Fatalf("recovery made unexpected requests: streams=%d snapshots=%d", streams.Load(), snapshots.Load())
	}
}
