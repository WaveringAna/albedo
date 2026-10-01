//go:build unix

// Acknowledgement loss must not duplicate effects in the real daemon. The
// proxy waits for admission before cutting the client response, so these
// scenarios cannot accidentally test a failure that preceded execution.
package e2e

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"sync"
	"testing"
	"time"

	"albedo/cli/internal/app"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui"
)

type acknowledgementFault string

const (
	dropAcknowledgement     acknowledgementFault = "drop"
	truncateAcknowledgement acknowledgementFault = "truncate"
	rejectAcknowledgement   acknowledgementFault = "server-error"
	cancelAcknowledgement   acknowledgementFault = "cancel"
)

type acknowledgementProxy struct {
	failure    error
	connection *daemon.Connection
	admitted   chan struct{}
	responses  [][]byte
	mu         sync.Mutex
}

func cutAcknowledgement(t *testing.T, path string, fault acknowledgementFault) *acknowledgementProxy {
	t.Helper()
	upstream := conn(t).Snapshot()
	destination, err := url.Parse(conn(t).BaseURL())
	if err != nil {
		t.Fatal(err)
	}
	proxy := &acknowledgementProxy{admitted: make(chan struct{}, 1)}
	transport := &http.Transport{}
	t.Cleanup(transport.CloseIdleConnections)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		forwarded := request.Clone(request.Context())
		forwarded.URL.Scheme, forwarded.URL.Host = destination.Scheme, destination.Host
		forwarded.RequestURI = ""
		forwarded.Host = destination.Host
		response, forwardErr := transport.RoundTrip(forwarded)
		if forwardErr != nil {
			proxy.mu.Lock()
			proxy.failure = forwardErr
			proxy.mu.Unlock()
			http.Error(writer, forwardErr.Error(), http.StatusBadGateway)
			return
		}
		defer response.Body.Close()
		body, readErr := io.ReadAll(io.LimitReader(response.Body, 1<<20))
		if readErr != nil {
			proxy.mu.Lock()
			proxy.failure = readErr
			proxy.mu.Unlock()
			http.Error(writer, readErr.Error(), http.StatusBadGateway)
			return
		}
		isMutation := request.Method == http.MethodPost && request.URL.Path == path
		first := false
		if isMutation {
			proxy.mu.Lock()
			first = len(proxy.responses) == 0
			proxy.responses = append(proxy.responses, body)
			if response.StatusCode < 200 || response.StatusCode >= 300 {
				proxy.failure = fmt.Errorf("daemon rejected mutation: %s: %s", response.Status, body)
			}
			proxy.mu.Unlock()
		}
		if isMutation && first {
			proxy.admitted <- struct{}{}
			switch fault {
			case dropAcknowledgement:
				socket, _, hijackErr := writer.(http.Hijacker).Hijack()
				if hijackErr == nil {
					_ = socket.Close()
				}
				return
			case truncateAcknowledgement:
				writer.Header().Set("Content-Length", strconv.Itoa(len(body)+1))
				writer.WriteHeader(response.StatusCode)
				_, _ = writer.Write(body[:len(body)/2])
				return
			case rejectAcknowledgement:
				http.Error(writer, "acknowledgement unavailable", http.StatusServiceUnavailable)
				return
			case cancelAcknowledgement:
				<-request.Context().Done()
				return
			}
		}
		maps.Copy(writer.Header(), response.Header)
		writer.WriteHeader(response.StatusCode)
		_, _ = writer.Write(body)
	}))
	t.Cleanup(server.Close)
	upstream.Port = server.Listener.Addr().(*net.TCPAddr).Port
	home := t.TempDir()
	record, err := json.Marshal(upstream)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "daemon.json"), record, 0o600); err != nil {
		t.Fatal(err)
	}
	proxy.connection = daemon.NewConnection(upstream, home)
	t.Cleanup(proxy.connection.HTTPClient().CloseIdleConnections)
	return proxy
}

func (proxy *acknowledgementProxy) assertSingleEffect(t *testing.T, operationErr error) []byte {
	t.Helper()
	if _, uncertain := errors.AsType[*daemon.UncertainOutcomeError](operationErr); !uncertain {
		t.Fatalf("lost acknowledgement should be uncertain, got %v", operationErr)
	}
	return proxy.acceptedResponse(t)
}

func (proxy *acknowledgementProxy) acceptedResponse(t *testing.T) []byte {
	t.Helper()
	proxy.mu.Lock()
	defer proxy.mu.Unlock()
	if proxy.failure != nil {
		t.Fatal(proxy.failure)
	}
	if len(proxy.responses) != 1 {
		t.Fatalf("daemon admitted %d mutations, want one", len(proxy.responses))
	}
	return slices.Clone(proxy.responses[0])
}

func TestLostCreationAcknowledgementCreatesOneSession(t *testing.T) {
	providerRoute(t, echoReply)
	for _, fault := range []acknowledgementFault{dropAcknowledgement, truncateAcknowledgement, rejectAcknowledgement} {
		t.Run(string(fault), func(t *testing.T) {
			workspace := t.TempDir()
			proxy := cutAcknowledgement(t, "/sessions", fault)
			service := app.Service{Connect: func(context.Context) (*daemon.Connection, error) { return proxy.connection, nil }}
			_, err := service.PrepareOpen(context.Background(), app.OpenOptions{Workspace: workspace, Fresh: true})
			accepted := proxy.assertSingleEffect(t, err)
			var created daemon.Session
			if decodeErr := json.Unmarshal(accepted, &created); decodeErr != nil || created.ID == "" {
				t.Fatalf("accepted session: %s, %v", accepted, decodeErr)
			}
			sessions, err := daemon.RequestOperation[[]daemon.Session](context.Background(), conn(t), daemon.Operation{Name: "list sessions", Method: http.MethodGet, Path: "/sessions", Policy: daemon.ReadRecovery})
			if err != nil {
				t.Fatal(err)
			}
			count := 0
			for _, session := range sessions {
				if session.Workspace == workspace {
					count++
				}
			}
			if count != 1 {
				t.Fatalf("workspace contains %d sessions, want one", count)
			}
		})
	}
}

func TestLostTUICreationAcknowledgementKeepsActiveSession(t *testing.T) {
	providerRoute(t, echoReply)
	initial := daemonSession(t, newSession(t, t.TempDir()))
	workspace := t.TempDir()
	proxy := cutAcknowledgement(t, "/sessions", dropAcknowledgement)
	driver := driveTUIWithConnection(t, &initial, proxy.connection)
	defer driver.App.Chat.Close()
	driver.Dispatch(tui.FolderNewSessionMsg{Workspace: workspace})
	accepted := proxy.acceptedResponse(t)
	var created daemon.Session
	if decodeErr := json.Unmarshal(accepted, &created); decodeErr != nil || created.ID == "" {
		t.Fatalf("accepted session: %s, %v", accepted, decodeErr)
	}
	if driver.App.ActiveSession == nil || driver.App.ActiveSession.ID != initial.ID || !driver.App.Chat.Notices.HasError() {
		t.Fatalf("lost creation response changed the active session or hid its error: %+v", driver.App.Chat.Notices)
	}
	count := 0
	for _, session := range daemonSessions(t) {
		if session.Workspace == workspace {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("TUI creation admitted %d sessions, want one", count)
	}
}

func TestLostSubmissionAcknowledgementSendsOneTurn(t *testing.T) {
	profile := providerRoute(t, echoReply)
	id := newSession(t, t.TempDir())
	proxy := cutAcknowledgement(t, "/sessions/"+id+"/events", dropAcknowledgement)
	client := daemon.NewChatClient(proxy.connection, id)
	_, err := client.Send(context.Background(), "exactly one uncertain turn", nil)
	proxy.assertSingleEffect(t, err)
	waitIdle(t, id, profile, 1)
	if count := len(suite.provider.requests(profile)); count != 1 {
		t.Fatalf("provider received %d turns, want one", count)
	}
	history, err := daemon.NewChatClient(conn(t), id).History(context.Background(), 0, 120)
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, event := range history.Events {
		if event.Type == daemon.EventUser {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("transcript contains %d user submissions, want one", count)
	}
}

func TestLostCommandAcknowledgementAddsOneWorkItem(t *testing.T) {
	providerRoute(t, echoReply)
	id := newSession(t, t.TempDir())
	path := "/sessions/" + id + "/commands"
	proxy := cutAcknowledgement(t, path, truncateAcknowledgement)
	session := daemonSession(t, id)
	driver := driveTUIWithConnection(t, &session, proxy.connection)
	defer driver.App.Chat.Close()
	driver.Dispatch(tui.ChatExecuteCommandMsg{Name: "/work", Args: "add one uncertain work item"})
	proxy.acceptedResponse(t)
	if driver.App.ActiveSession == nil || driver.App.ActiveSession.ID != id || !driver.App.Chat.Notices.HasError() {
		t.Fatalf("command acknowledgement loss changed the active session or hid its error: %+v", driver.App.Chat.Notices)
	}
	listed, err := daemon.RequestOperation[struct {
		Result struct {
			Page struct {
				Rows []struct {
					Text string `json:"text"`
				} `json:"rows"`
			} `json:"page"`
		} `json:"result"`
	}](context.Background(), conn(t), daemon.Operation{Name: "list work", Method: http.MethodPost, Path: path, Body: map[string]any{"name": "/work", "args": map[string]string{}}, Policy: daemon.AuthRecovery})
	if err != nil {
		t.Fatal(err)
	}
	if len(listed.Result.Page.Rows) != 1 || listed.Result.Page.Rows[0].Text != "one uncertain work item" {
		t.Fatalf("ledger after lost acknowledgement: %+v", listed)
	}
}

func TestCancellationAfterAdmissionPreservesUncertainCause(t *testing.T) {
	profile := providerRoute(t, echoReply)
	proxy := cutAcknowledgement(t, "/sessions", cancelAcknowledgement)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := make(chan error, 1)
	workspace := t.TempDir()
	go func() {
		_, err := daemon.RequestOperation[daemon.Session](ctx, proxy.connection, daemon.Operation{
			Name: "create session", Method: http.MethodPost, Path: "/sessions", Policy: daemon.AuthRecovery,
			Body: map[string]string{"workspace": workspace, "provider": profile},
		})
		result <- err
	}()
	select {
	case <-proxy.admitted:
		cancel()
	case <-time.After(20 * time.Second):
		t.Fatal("mutation was not admitted")
	}
	select {
	case err := <-result:
		proxy.assertSingleEffect(t, err)
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("uncertain error lost cancellation cause: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("canceled operation did not return")
	}
}

func TestLostSignInAcknowledgementStartsOneLocalFlow(t *testing.T) {
	proxy := cutAcknowledgement(t, "/auth/antigravity", dropAcknowledgement)
	_, err := daemon.StartSignIn(context.Background(), proxy.connection, "antigravity")
	accepted := proxy.assertSingleEffect(t, err)
	var started daemon.StartedSignIn
	if decodeErr := json.Unmarshal(accepted, &started); decodeErr != nil || started.ID == "" {
		t.Fatalf("accepted sign-in: %s, %v", accepted, decodeErr)
	}
	t.Cleanup(func() {
		if cancelErr := daemon.CancelSignIn(context.Background(), conn(t), started.ID); cancelErr != nil {
			t.Errorf("cancel sign-in: %v", cancelErr)
		}
	})
	status, err := daemon.PollSignIn(context.Background(), conn(t), started.ID)
	if err != nil || status.State != "waiting" {
		t.Fatalf("the one admitted local flow: %+v, %v", status, err)
	}
	// Starting only allocates a loopback listener and builds an authorization
	// URL. No callback or pasted code is supplied, so no exchange reaches a provider.
}

func TestCoreAuthenticationRefusalRecoversBeforeCreation(t *testing.T) {
	profile := providerRoute(t, echoReply)
	snapshot := conn(t).Snapshot()
	snapshot.Token = "expired-client-token"
	stale := daemon.NewConnection(snapshot, suite.home)
	t.Cleanup(stale.HTTPClient().CloseIdleConnections)
	workspace := t.TempDir()
	created, err := daemon.RequestOperation[daemon.Session](context.Background(), stale, daemon.Operation{
		Name: "create session", Method: http.MethodPost, Path: "/sessions", Policy: daemon.AuthRecovery,
		Body: map[string]string{"workspace": workspace, "provider": profile},
	})
	if err != nil || created.ID == "" {
		t.Fatalf("creation after pre-admission refusal: %+v, %v", created, err)
	}
	if stale.Token() != conn(t).Token() {
		t.Fatal("recovery did not update credentials")
	}
	sessions, err := daemon.RequestOperation[[]daemon.Session](context.Background(), conn(t), daemon.Operation{Name: "list sessions", Method: http.MethodGet, Path: "/sessions", Policy: daemon.ReadRecovery})
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, session := range sessions {
		if session.Workspace == workspace {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("authentication recovery created %d sessions, want one", count)
	}
}
