//go:build unix

// Acknowledgement loss must not duplicate effects in the real daemon. The
// proxy waits for admission before cutting the client response, so these
// scenarios cannot accidentally test a failure that preceded execution.
package e2e

import (
	"bytes"
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

	tea "charm.land/bubbletea/v2"
	"testing"
	"time"

	"albedo/cli/internal/app"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui"
)

type acknowledgementFault string

const (
	dropAcknowledgement        acknowledgementFault = "drop"
	truncateAcknowledgement    acknowledgementFault = "truncate"
	rejectAcknowledgement      acknowledgementFault = "server-error"
	cancelAcknowledgement      acknowledgementFault = "cancel"
	emptyAcknowledgement       acknowledgementFault = "empty"
	malformedAcknowledgement   acknowledgementFault = "malformed"
	missingAcknowledgement     acknowledgementFault = "missing-fields"
	negativeAcknowledgement    acknowledgementFault = "negative"
	wrongStatusAcknowledgement acknowledgementFault = "wrong-status"
)

type acknowledgementProxy struct {
	failure    error
	connection *daemon.Connection
	admitted   chan struct{}
	responses  [][]byte
	requests   []string
	mu         sync.Mutex
}

func cutAcknowledgement(t *testing.T, path string, fault acknowledgementFault) *acknowledgementProxy {
	t.Helper()
	return mutateAcknowledgement(t, path, fault, nil, nil)
}

func mutateAcknowledgement(t *testing.T, path string, fault acknowledgementFault, matches func([]byte) bool, transform func([]byte) ([]byte, error)) *acknowledgementProxy {
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
		requestBody, bodyErr := io.ReadAll(request.Body)
		if bodyErr != nil {
			http.Error(writer, bodyErr.Error(), http.StatusBadRequest)
			return
		}
		proxy.mu.Lock()
		proxy.requests = append(proxy.requests, request.Method+" "+request.URL.Path)
		proxy.mu.Unlock()
		forwarded := request.Clone(request.Context())
		forwarded.Body = io.NopCloser(bytes.NewReader(requestBody))
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
		isMutation := request.Method == http.MethodPost && request.URL.Path == path && (matches == nil || matches(requestBody))
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
			if transform != nil {
				transformed, transformErr := transform(body)
				if transformErr != nil {
					proxy.mu.Lock()
					proxy.failure = transformErr
					proxy.mu.Unlock()
					http.Error(writer, transformErr.Error(), http.StatusBadGateway)
					return
				}
				writer.WriteHeader(response.StatusCode)
				_, _ = writer.Write(transformed)
				return
			}
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
			case emptyAcknowledgement:
				writer.WriteHeader(response.StatusCode)
				return
			case malformedAcknowledgement:
				writer.WriteHeader(response.StatusCode)
				_, _ = writer.Write([]byte("{"))
				return
			case missingAcknowledgement:
				writer.WriteHeader(response.StatusCode)
				_, _ = writer.Write([]byte("{}"))
				return
			case negativeAcknowledgement:
				writer.WriteHeader(response.StatusCode)
				_, _ = writer.Write([]byte(`{"ok":false,"queued":false,"submitted":false}`))
				return
			case wrongStatusAcknowledgement:
				writer.WriteHeader(http.StatusCreated)
				_, _ = writer.Write(body)
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
	for _, fault := range []acknowledgementFault{dropAcknowledgement, truncateAcknowledgement, rejectAcknowledgement, emptyAcknowledgement, malformedAcknowledgement, missingAcknowledgement} {
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

func TestInvalidTUICreationAcknowledgementKeepsActiveSession(t *testing.T) {
	profile := providerRoute(t, echoReply)
	for _, fault := range []acknowledgementFault{dropAcknowledgement, emptyAcknowledgement, malformedAcknowledgement, missingAcknowledgement} {
		t.Run(string(fault), func(t *testing.T) {
			initial := daemonSession(t, newFaultSession(t, profile))
			workspace := t.TempDir()
			proxy := cutAcknowledgement(t, "/sessions", fault)
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
		})
	}
}

func TestInvalidSubmissionAcknowledgementSendsOneTurn(t *testing.T) {
	for _, fault := range []acknowledgementFault{dropAcknowledgement, emptyAcknowledgement, malformedAcknowledgement, missingAcknowledgement, negativeAcknowledgement, wrongStatusAcknowledgement} {
		t.Run(string(fault), func(t *testing.T) {
			profile := "invalid-submit-" + string(fault)
			if err := suite.provider.addProfile(profile, echoReply); err != nil {
				t.Fatal(err)
			}
			id := newFaultSession(t, profile)
			proxy := cutAcknowledgement(t, "/sessions/"+id+"/events", fault)
			client := daemon.NewChatClient(proxy.connection, id)
			_, err := client.Send(context.Background(), "exactly one uncertain turn", nil)
			proxy.assertSingleEffect(t, err)
			if fault != dropAcknowledgement {
				protocol, ok := errors.AsType[*daemon.ProtocolError](err)
				if !ok || protocol.Code != "invalid_response" {
					t.Fatalf("invalid response cause: %v", err)
				}
			}
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
		})
	}
}

func TestInvalidCommandAcknowledgementAddsOneWorkItem(t *testing.T) {
	profile := providerRoute(t, echoReply)
	for _, fault := range []acknowledgementFault{truncateAcknowledgement, emptyAcknowledgement, malformedAcknowledgement, missingAcknowledgement, negativeAcknowledgement, wrongStatusAcknowledgement} {
		t.Run(string(fault), func(t *testing.T) {
			id := newFaultSession(t, profile)
			path := "/sessions/" + id + "/commands"
			proxy := cutAcknowledgement(t, path, fault)
			session := daemonSession(t, id)
			driver := driveTUIWithConnection(t, &session, proxy.connection)
			defer driver.App.Chat.Close()
			driver.Dispatch(tui.ChatExecuteCommandMsg{Name: "/work", Args: "add one uncertain work item"})
			proxy.acceptedResponse(t)
			if driver.App.ActiveSession == nil || driver.App.ActiveSession.ID != id || !driver.App.Chat.Notices.HasError() {
				t.Fatalf("command acknowledgement loss changed the active session or hid its error: %+v", driver.App.Chat.Notices)
			}
			listed, err := daemon.ExecutePageCommand(context.Background(), conn(t), id, map[string]any{"name": "/work", "args": map[string]string{}})
			if err != nil {
				t.Fatal(err)
			}
			if len(listed.Page.Rows) != 1 || listed.Page.Rows[0].Text != "one uncertain work item" {
				t.Fatalf("ledger after lost acknowledgement: %+v", listed)
			}
		})
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
		_, err := daemon.CreateSession(ctx, proxy.connection, map[string]string{"workspace": workspace, "provider": profile})
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
	created, err := daemon.CreateSession(context.Background(), stale, map[string]string{"workspace": workspace, "provider": profile})
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

func newFaultSession(t *testing.T, profile string) string {
	t.Helper()
	created, err := daemon.CreateSession(t.Context(), conn(t), map[string]string{"workspace": t.TempDir(), "provider": profile})
	if err != nil {
		t.Fatal(err)
	}
	return created.ID
}

func TestWebhookCreationMissingGeneratedSecretStopsAfterOneEffect(t *testing.T) {
	profile := providerRoute(t, echoReply)
	id := newFaultSession(t, profile)
	if _, err := daemon.SelectExtension(t.Context(), conn(t), id, map[string]any{"name": "webhooks", "enabled": true, "scope": "session"}); err != nil {
		t.Fatal(err)
	}
	path := "/sessions/" + id + "/commands"
	proxy := mutateAcknowledgement(t, path, "", func(body []byte) bool {
		var command struct {
			Args map[string]string `json:"args"`
			Name string            `json:"name"`
		}
		return json.Unmarshal(body, &command) == nil && command.Name == "/webhooks" && command.Args["action"] == "create_in"
	}, func(body []byte) ([]byte, error) {
		var envelope map[string]json.RawMessage
		if err := json.Unmarshal(body, &envelope); err != nil {
			return nil, err
		}
		var result map[string]json.RawMessage
		if err := json.Unmarshal(envelope["result"], &result); err != nil {
			return nil, err
		}
		if _, present := result["secret"]; !present {
			return nil, errors.New("daemon did not generate a secret")
		}
		delete(result, "secret")
		encoded, err := json.Marshal(result)
		if err != nil {
			return nil, err
		}
		envelope["result"] = encoded
		return json.Marshal(envelope)
	})
	session := daemonSession(t, id)
	driver := driveTUIWithConnection(t, &session, proxy.connection)
	defer driver.App.Chat.Close()
	driver.Dispatch(tui.ChatOpenWebhooksPageMsg{})
	if !driver.App.WebhooksPage.Loaded || driver.App.WebhooksPage.Error != "" {
		t.Fatalf("open creation screen: %s", driver.App.WebhooksPage.Error)
	}
	driver.Dispatch(tea.KeyPressMsg{Code: 'n', Text: "n"})
	driver.Type("missing-secret")
	// A changed signature adds a second mutation, which must not run after the lost secret.
	driver.App.WebhooksPage.Form.Inputs["header"].SetValue("x-custom-signature")
	proxy.mu.Lock()
	before := len(proxy.requests)
	proxy.mu.Unlock()
	driver.Dispatch(tea.KeyPressMsg{Code: 's', Mod: tea.ModCtrl})
	accepted := proxy.acceptedResponse(t)
	page := driver.App.WebhooksPage
	if page.Saving || page.Loading || page.Form == nil || page.Error == "" || page.Notice != "" || page.Reveal != nil {
		t.Fatalf("uncertain creation state: %+v", page)
	}
	proxy.mu.Lock()
	requests := slices.Clone(proxy.requests[before:])
	proxy.mu.Unlock()
	if !slices.Equal(requests, []string{"POST " + path}) {
		t.Fatalf("creation replayed, configured a signature, or refreshed: %v", requests)
	}
	var original struct {
		Result struct{ Hook daemon.Webhook } `json:"result"`
	}
	if err := json.Unmarshal(accepted, &original); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, err := daemon.ExecuteCommand(context.Background(), conn(t), id, map[string]any{"name": "/webhooks", "args": map[string]string{"action": "delete", "details": original.Result.Hook.ID}})
		if err != nil {
			t.Error(err)
		}
	})
	listed, err := daemon.ExecuteCommand(t.Context(), conn(t), id, map[string]any{"name": "/webhooks", "args": map[string]string{"action": "list"}})
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, entry := range listed.Webhooks.Hooks {
		if entry.Hook.Session == id && entry.Hook.Name == "missing-secret" {
			count++
			if entry.Hook.Header != "x-albedo-signature" {
				t.Fatal("signature step ran without the generated secret")
			}
		}
	}
	if count != 1 {
		t.Fatalf("persisted %d hooks, want one", count)
	}
}
