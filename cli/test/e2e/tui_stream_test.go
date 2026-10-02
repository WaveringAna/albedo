//go:build unix

// Stream faults are injected ahead of the shared real daemon; the TUI must
// recover its durable transcript once, then stop visibly if the wire stays bad.
package e2e

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui"
	tea "charm.land/bubbletea/v2"
)

type streamFaultProxy struct {
	connection      *daemon.Connection
	mu              sync.Mutex
	cursors         []string
	generations     []string
	firstCursor     int64
	firstGeneration string
	reconnected     chan struct{}
}

func faultSessionStream(t *testing.T, session string, fault string) *streamFaultProxy {
	t.Helper()
	destination, err := url.Parse(conn(t).BaseURL())
	if err != nil {
		t.Fatal(err)
	}
	forward := httputil.NewSingleHostReverseProxy(destination)
	forward.FlushInterval = -1
	proxy := &streamFaultProxy{reconnected: make(chan struct{}, 1)}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/sessions/"+session+"/stream" {
			proxy.mu.Lock()
			proxy.cursors = append(proxy.cursors, r.URL.Query().Get("after_seq"))
			proxy.generations = append(proxy.generations, r.URL.Query().Get("after_generation"))
			count := len(proxy.cursors)
			proxy.mu.Unlock()
			if fault == "eof" || fault == "after-history" {
				if count == 1 {
					outgoing := r.Clone(r.Context())
					outgoing.URL.Scheme, outgoing.URL.Host = destination.Scheme, destination.Host
					outgoing.RequestURI = ""
					response, err := conn(t).HTTPClient().Do(outgoing)
					if err != nil {
						http.Error(w, err.Error(), 502)
						return
					}
					defer response.Body.Close()
					scanner := bufio.NewScanner(response.Body)
					scanner.Buffer(make([]byte, 4096), 10*1024*1024)
					w.Header().Set("Content-Type", "text/event-stream")
					for scanner.Scan() {
						line := scanner.Text()
						_, _ = fmt.Fprintln(w, line)
						if strings.HasPrefix(line, "data: ") {
							var envelope struct {
								Cursor     int64  `json:"cursor"`
								Generation string `json:"generation"`
							}
							if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &envelope); err != nil {
								t.Error(err)
							}
							proxy.mu.Lock()
							proxy.firstCursor = envelope.Cursor
							proxy.firstGeneration = envelope.Generation
							proxy.mu.Unlock()
						}
						if line == "" {
							return
						}
					}
					if err := scanner.Err(); err != nil {
						t.Errorf("reading injected EOF frame: %v", err)
					} else {
						t.Error("daemon stream ended before a complete SSE frame")
					}
					return
				}
				if fault == "after-history" && count == 2 {
					w.Header().Set("Content-Type", "text/event-stream")
					_, _ = io.WriteString(w, "data: "+`{"generation":"invalid-replacement","cursor":10,"events":[{"type":"text","text":"poison must stay hidden"}]}`+"\n\n")
					return
				}
				select {
				case proxy.reconnected <- struct{}{}:
				default:
				}
			} else if count == 1 || fault == "repeated" {
				w.Header().Set("Content-Type", "text/event-stream")
				_, _ = io.WriteString(w, "data: "+`{"generation":"fault","cursor":10,"events":[{"type":"text","text":"poison must stay hidden"},{"type":"message","role":"assistant","text":false}]}`+"\n\n")
				return
			}
		}
		forward.ServeHTTP(w, r)
	}))
	t.Cleanup(server.Close)
	snapshot := conn(t).Snapshot()
	snapshot.Port = server.Listener.Addr().(*net.TCPAddr).Port
	proxy.connection = daemon.NewConnection(snapshot, "")
	t.Cleanup(proxy.connection.HTTPClient().CloseIdleConnections)
	return proxy
}

func (proxy *streamFaultProxy) requests() []string {
	proxy.mu.Lock()
	defer proxy.mu.Unlock()
	return append([]string(nil), proxy.cursors...)
}

// Commands run independently, like Bubble Tea: one pending stream read must
// not prevent the status result or a terminal notice from reaching the model.
func streamMessages(ctx context.Context, cmd tea.Cmd, inbox chan<- tea.Msg) {
	if cmd == nil {
		return
	}
	go func() {
		msg := cmd()
		if batch, ok := msg.(tea.BatchMsg); ok {
			for _, next := range batch {
				streamMessages(ctx, next, inbox)
			}
			return
		}
		if msg != nil {
			select {
			case inbox <- msg:
			case <-ctx.Done():
			}
		}
	}()
}

func pumpStreamUntil(t *testing.T, driver *tuiDriver, condition func(tea.Msg) bool) tea.Msg {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	inbox := make(chan tea.Msg, 32)
	streamMessages(ctx, driver.App.Chat.Init(), inbox)
	for {
		select {
		case msg := <-inbox:
			cmd := driver.Update(msg)
			if condition(msg) {
				return msg
			}
			streamMessages(ctx, cmd, inbox)
		case <-ctx.Done():
			t.Fatalf("stream did not reach expected state:\n%s", driver.View())
		}
	}
}

func TestTUIStreamProtocolFailureRecoversDurableHistoryOnce(t *testing.T) {
	profile := providerRoute(t, echoReply)
	session := daemonSession(t, newSession(t, t.TempDir()))
	if _, err := daemon.NewChatClient(conn(t), session.ID).Send(t.Context(), "durable stream recovery", nil); err != nil {
		t.Fatal(err)
	}
	waitIdle(t, session.ID, profile, 1)
	proxy := faultSessionStream(t, session.ID, "once")
	driver := driveTUIWithConnection(t, &session, proxy.connection)
	t.Cleanup(driver.App.Chat.Close)
	driver.Update(tea.WindowSizeMsg{Width: 100, Height: 50})
	recoverySeen := false
	pumpStreamUntil(t, driver, func(msg tea.Msg) bool {
		if result, ok := msg.(tui.ChatStreamResultMsg); ok && result.Recovering {
			recoverySeen = true
		}
		event, ok := msg.(tui.ChatStreamEventMsg)
		return ok && event.Event.Type == daemon.EventMessage && strings.Contains(event.Event.Text, "durable stream recovery")
	})
	view := driver.View()
	if !recoverySeen || strings.Contains(view, "poison must stay hidden") || strings.Count(view, "durable stream recovery") != 2 {
		t.Fatalf("reset lost or duplicated durable transcript:\n%s", view)
	}
	requests := proxy.requests()
	if len(requests) != 2 || requests[1] != "" {
		t.Fatalf("protocol recovery did not request exactly one durable reset: %v", requests)
	}
}

func TestTUIProtocolFailureStopsUntilTheSessionIsReopened(t *testing.T) {
	providerRoute(t, echoReply)
	session := daemonSession(t, newSession(t, t.TempDir()))
	proxy := faultSessionStream(t, session.ID, "repeated")
	driver := driveTUIWithConnection(t, &session, proxy.connection)
	t.Cleanup(func() { driver.App.Chat.Close() })
	terminal := pumpStreamUntil(t, driver, func(msg tea.Msg) bool {
		result, ok := msg.(tui.ChatStreamResultMsg)
		return ok && !result.Recovering
	})
	failure, ok := errors.AsType[*daemon.StreamError](terminal.(tui.ChatStreamResultMsg).Err)
	if !ok || failure.Kind != daemon.StreamProtocol || !driver.App.Chat.Notices.HasError() || strings.Contains(driver.View(), "poison must stay hidden") {
		t.Fatalf("protocol stop not visible or malformed text escaped:\n%s", driver.View())
	}
	// Wait beyond both initial retry delays: a stopped attachment must stay stopped.
	time.Sleep(1600 * time.Millisecond)
	if requests := proxy.requests(); len(requests) != 2 {
		t.Fatalf("poison stream retried forever: %v", requests)
	}
	if cmd := driver.Update(tui.ChatStatusPollMsg{SessionID: session.ID, Generation: driver.App.Chat.Generation}); cmd != nil {
		t.Fatal("terminal attachment resumed status polling")
	}
	driver.Update(tui.FolderOpenSessionMsg{Session: session})
	before := driver.View()
	if cmd := driver.Update(terminal); cmd != nil || driver.View() != before {
		t.Fatal("stale terminal failure affected the reopened session")
	}
}

func TestTUIDeletedSessionStopsItsStreamAndStatusPolling(t *testing.T) {
	providerRoute(t, echoReply)
	session := daemonSession(t, newSession(t, t.TempDir()))
	if _, err := daemon.DeleteSession(t.Context(), conn(t), session.ID, false); err != nil {
		t.Fatal(err)
	}
	driver := driveTUI(t, &session)
	t.Cleanup(driver.App.Chat.Close)
	msg := pumpStreamUntil(t, driver, func(msg tea.Msg) bool {
		result, ok := msg.(tui.ChatStreamResultMsg)
		return ok && !result.Recovering
	})
	result := msg.(tui.ChatStreamResultMsg)
	failure, ok := errors.AsType[*daemon.StreamError](result.Err)
	api, apiOK := errors.AsType[*daemon.APIError](result.Err)
	if !ok || failure.Kind != daemon.StreamTerminal || !apiOK || api.StatusCode != http.StatusNotFound {
		t.Fatalf("deleted session did not terminate: %v", result.Err)
	}
	if cmd := driver.Update(tui.ChatStatusPollMsg{SessionID: session.ID, Generation: driver.App.Chat.Generation}); cmd != nil {
		t.Fatal("deleted session kept polling")
	}
	if !driver.App.Chat.Notices.HasError() || !strings.Contains(driver.View(), api.Error()) {
		t.Fatalf("deleted session left no visible failure reason:\n%s", driver.View())
	}
}

func TestTUIStreamEOFReconnectsFromConsumedCursor(t *testing.T) {
	profile := providerRoute(t, echoReply)
	session := daemonSession(t, newSession(t, t.TempDir()))
	client := daemon.NewChatClient(conn(t), session.ID)
	if _, err := client.Send(t.Context(), "before EOF", nil); err != nil {
		t.Fatal(err)
	}
	waitIdle(t, session.ID, profile, 1)
	proxy := faultSessionStream(t, session.ID, "eof")
	driver := driveTUIWithConnection(t, &session, proxy.connection)
	t.Cleanup(driver.App.Chat.Close)
	driver.Update(tea.WindowSizeMsg{Width: 100, Height: 60})
	sent := make(chan error, 1)
	go func() {
		select {
		case <-proxy.reconnected:
			_, err := client.Send(t.Context(), "after EOF", nil)
			sent <- err
		case <-t.Context().Done():
			sent <- t.Context().Err()
		}
	}()
	pumpStreamUntil(t, driver, func(msg tea.Msg) bool {
		if result, ok := msg.(tui.ChatStreamResultMsg); ok {
			t.Errorf("ordinary EOF reported a terminal or protocol failure: %v", result.Err)
		}
		event, ok := msg.(tui.ChatStreamEventMsg)
		return ok && event.Event.Type == daemon.EventMessage && strings.Contains(event.Event.Text, "after EOF")
	})
	if err := <-sent; err != nil {
		t.Fatal(err)
	}
	proxy.mu.Lock()
	requests, first := append([]string(nil), proxy.cursors...), proxy.firstCursor
	generations, firstGeneration := append([]string(nil), proxy.generations...), proxy.firstGeneration
	proxy.mu.Unlock()
	if len(requests) != 2 || requests[1] != fmt.Sprint(first) || generations[1] != firstGeneration || firstGeneration == "" {
		t.Fatalf("EOF lost consumed cursor: requests=%v, cursor=%d", requests, first)
	}
	view := driver.View()
	if strings.Count(view, "before EOF") != 2 || strings.Count(view, "after EOF") != 2 {
		t.Fatalf("EOF replay lost or duplicated rows:\n%s", view)
	}
}

func TestTUIResetReplacesHistoryAndPreservesOlderNavigation(t *testing.T) {
	profile := providerRoute(t, echoReply)
	session := daemonSession(t, newSession(t, t.TempDir()))
	client := daemon.NewChatClient(conn(t), session.ID)
	const turns = 62
	for index := range turns {
		if _, err := client.Send(t.Context(), fmt.Sprintf("history row %03d", index), nil); err != nil {
			t.Fatal(err)
		}
		waitIdle(t, session.ID, profile, index+1)
	}
	proxy := faultSessionStream(t, session.ID, "after-history")
	driver := driveTUIWithConnection(t, &session, proxy.connection)
	t.Cleanup(driver.App.Chat.Close)
	driver.Update(tea.WindowSizeMsg{Width: 100, Height: 50})
	recoverySeen := false
	pumpStreamUntil(t, driver, func(msg tea.Msg) bool {
		if result, ok := msg.(tui.ChatStreamResultMsg); ok && result.Recovering {
			recoverySeen = true
		}
		event, ok := msg.(tui.ChatStreamEventMsg)
		return recoverySeen && ok && event.Event.Type == daemon.EventMessage && strings.Contains(event.Event.Text, "history row 061")
	})
	if requests := proxy.requests(); len(requests) != 3 || requests[2] != "" {
		t.Fatalf("generation failure did not recover with a fresh subscription: %v", requests)
	}
	seen := map[string]int{}
	for _, entry := range driver.App.Chat.History.Entries() {
		seen[entry.Text]++
	}
	if seen["history row 061"] != 1 || seen["history row 000"] != 0 || strings.Contains(driver.View(), "poison must stay hidden") {
		t.Fatalf("reset duplicated history or lost the tail boundary: %v", seen)
	}
	for range 4 {
		driver.Dispatch(tea.KeyPressMsg{Code: tea.KeyHome, Mod: tea.ModCtrl})
	}
	seen = map[string]int{}
	for _, entry := range driver.App.Chat.History.Entries() {
		seen[entry.Text]++
	}
	if seen["history row 000"] != 1 || seen["history row 061"] != 1 {
		t.Fatalf("older navigation after reset lost or duplicated rows: %v", seen)
	}
}
