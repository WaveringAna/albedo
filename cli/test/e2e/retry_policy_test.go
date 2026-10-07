//go:build unix

// Acknowledgement loss must not duplicate effects in the real daemon. The
// proxy waits for admission before cutting the client response, so these
// scenarios cannot accidentally test a failure that preceded execution.
package e2e

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"
	"sync"
	"sync/atomic"

	tea "charm.land/bubbletea/v2"
	"testing"
	"time"

	"albedo/cli/internal/app"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/localdaemon"
	"albedo/cli/internal/tui"
)

func TestLostCreationAcknowledgementCreatesOneSession(t *testing.T) {
	providerRoute(t, echoReply)
	// Default-changing tests finish before parallel bodies. These creations
	// send no turns and do not assert which provider the daemon selects.
	t.Parallel()
	for _, fault := range []acknowledgementFault{dropAcknowledgement, truncateAcknowledgement, rejectAcknowledgement, emptyAcknowledgement, malformedAcknowledgement, missingAcknowledgement} {
		t.Run(string(fault), func(t *testing.T) {
			workspace := t.TempDir()
			proxy := cutAcknowledgement(t, "/sessions", fault)
			service := app.Service{Connect: func(context.Context) (*daemon.Connection, error) { return proxy.connection, nil }}
			opened, err := service.PrepareOpen(context.Background(), app.OpenOptions{Workspace: workspace, Fresh: true})
			if err != nil {
				t.Fatal(err)
			}
			accepted := proxy.acceptedResponse(t)
			var created struct {
				ID string `json:"id"`
			}
			if decodeErr := json.Unmarshal(accepted, &created); decodeErr != nil || created.ID == "" {
				t.Fatalf("accepted session: %s, %v", accepted, decodeErr)
			}
			if opened.Selected == nil || opened.Selected.ID != created.ID {
				t.Fatal("lost creation receipt was not recovered")
			}
			sessions, err := daemon.ListSessions(context.Background(), conn(t))
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

func TestRejectedCreationReceiptRecoversWithoutAllocatingSession(t *testing.T) {
	t.Parallel()
	workspace := t.TempDir()
	handle, err := daemon.NewCreation(daemon.CreateSessionRequest{Workspace: workspace, Provider: "missing-creation-profile"})
	if err != nil {
		t.Fatal(err)
	}
	_, err = daemon.CreateSessionOperation(t.Context(), conn(t), handle)
	initial, ok := errors.AsType[*daemon.APIError](err)
	if !ok || initial.StatusCode != http.StatusBadRequest {
		t.Fatalf("unknown provider did not reject creation: %v", err)
	}
	// The creation resource retains its rejection without allocating a session.
	created, err := daemon.ResolveCreation(t.Context(), conn(t), handle)
	recovered, ok := errors.AsType[*daemon.APIError](err)
	if !ok || recovered.StatusCode != initial.StatusCode || created.ID != "" {
		t.Fatalf("resolve rejected creation: %+v, %v", created, err)
	}
	sessions, err := daemon.ListSessions(t.Context(), conn(t))
	if err != nil {
		t.Fatal(err)
	}
	for _, session := range sessions {
		if session.Workspace == workspace {
			t.Fatal("rejected creation allocated a session")
		}
	}
}

func TestInvalidTUICreationAcknowledgementRecoversCreatedSession(t *testing.T) {
	profile := providerRoute(t, echoReply)
	// Default-changing tests finish before parallel bodies. These creations
	// send no turns and do not assert which provider the daemon selects.
	t.Parallel()
	for _, fault := range []acknowledgementFault{dropAcknowledgement, emptyAcknowledgement, malformedAcknowledgement, missingAcknowledgement} {
		t.Run(string(fault), func(t *testing.T) {
			initial := daemonSession(t, newFaultSession(t, profile))
			workspace := t.TempDir()
			proxy := cutAcknowledgement(t, "/sessions", fault)
			driver := driveTUIWithConnection(t, &initial, proxy.connection)
			defer driver.App.Chat.Close()
			result := driver.Send(tui.FolderNewSessionMsg{Workspace: workspace})
			driver.Update(result)
			accepted := proxy.acceptedResponse(t)
			var created struct {
				ID string `json:"id"`
			}
			if decodeErr := json.Unmarshal(accepted, &created); decodeErr != nil || created.ID == "" {
				t.Fatalf("accepted session: %s, %v", accepted, decodeErr)
			}
			if driver.App.ActiveSession == nil || driver.App.ActiveSession.ID != created.ID || driver.App.Chat.Notices.HasError() {
				t.Fatalf("lost creation response did not recover its created session: %+v", driver.App.Chat.Notices)
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
			proxy := cutAcknowledgement(t, "/sessions/"+id+"/inputs/", fault)
			client := daemon.NewChatClient(proxy.connection, id)
			result, err := client.Send(context.Background(), "exactly one uncertain turn", nil)
			if err != nil || result == nil || result.OperationID == "" {
				t.Fatalf("recover submission: %+v %v", result, err)
			}
			proxy.acceptedResponse(t)
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
	t.Parallel()
	for _, fault := range []acknowledgementFault{truncateAcknowledgement, emptyAcknowledgement, malformedAcknowledgement, missingAcknowledgement, negativeAcknowledgement, wrongStatusAcknowledgement} {
		t.Run(string(fault), func(t *testing.T) {
			id := newFaultSession(t, profile)
			path := "/extensions/work/items"
			proxy := cutAcknowledgement(t, path, fault)
			page, err := daemon.LoadPage(t.Context(), conn(t), id, "/work")
			if err != nil {
				t.Fatal(err)
			}
			var action *daemon.PageAction
			for index := range page.Actions {
				candidate := &page.Actions[index]
				if candidate.Operation.Method == http.MethodPost && candidate.Operation.PathTemplate == path {
					action = candidate
					break
				}
			}
			if action == nil {
				t.Fatal("work creation action missing")
			}
			_, err = daemon.ExecutePageAction(t.Context(), proxy.connection, daemon.PageActionRequest{Action: *action, Session: page.Session, Form: map[string]json.RawMessage{"title": json.RawMessage(`"one uncertain work item"`), "notes": json.RawMessage(`""`), "parent_id": json.RawMessage(`null`)}})
			proxy.assertSingleEffect(t, err)
			listed, err := daemon.LoadPage(context.Background(), conn(t), id, "/work")
			if err != nil {
				t.Fatal(err)
			}
			if len(listed.Rows) != 1 || listed.Rows[0].Text != "one uncertain work item" {
				t.Fatalf("ledger after lost acknowledgement: %+v", listed)
			}
		})
	}
}

func TestCancellationAfterAdmissionPreservesUncertainCause(t *testing.T) {
	profile := providerRoute(t, echoReply)
	t.Parallel()
	proxy := cutAcknowledgement(t, "/sessions", cancelAcknowledgement)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := make(chan error, 1)
	workspace := t.TempDir()
	go func() {
		_, err := daemon.CreateSession(ctx, proxy.connection, daemon.CreateSessionRequest{Workspace: workspace, Provider: profile})
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
		uncertain, ok := errors.AsType[*daemon.UncertainOutcomeError](err)
		if !ok || uncertain.Handle == nil {
			t.Fatal("cancellation lost the operation handle")
		}
		original, resolveErr := daemon.ResolveCreation(t.Context(), proxy.connection, uncertain.Handle)
		if resolveErr != nil || original.ID == "" {
			t.Fatalf("resolve original creation: %+v %v", original, resolveErr)
		}
		proxy.acceptedResponse(t)
	case <-time.After(5 * time.Second):
		t.Fatal("canceled operation did not return")
	}
}

func TestLostSignInAcknowledgementStartsOneLocalFlow(t *testing.T) {
	proxy := cutAcknowledgement(t, "/auth/logins/", dropAcknowledgement)
	recovered, err := daemon.StartProviderLogin(context.Background(), proxy.connection, "antigravity", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	accepted := proxy.acceptedResponse(t)
	var started daemon.StartedSignIn
	if decodeErr := json.Unmarshal(accepted, &started); decodeErr != nil || started.ID == "" {
		t.Fatalf("accepted sign-in: %s, %v", accepted, decodeErr)
	}
	if recovered.ID != started.ID {
		t.Fatal("sign-in recovery changed the chosen ID")
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
	t.Parallel()
	snapshot := conn(t).Snapshot()
	snapshot.Token = "expired-client-token"
	stale := daemon.NewConnection(snapshot, func(ctx context.Context) (daemon.ConnectionSnapshot, error) {
		return localdaemon.Rediscover(ctx, suite.home)
	})
	t.Cleanup(stale.HTTPClient().CloseIdleConnections)
	workspace := t.TempDir()
	created, err := daemon.CreateSession(context.Background(), stale, daemon.CreateSessionRequest{Workspace: workspace, Provider: profile})
	if err != nil || created.ID == "" {
		t.Fatalf("creation after pre-admission refusal: %+v, %v", created, err)
	}
	if stale.Snapshot().Token != conn(t).Snapshot().Token {
		t.Fatal("recovery did not update credentials")
	}
	sessions, err := daemon.ListSessions(context.Background(), conn(t))
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
	created, err := daemon.CreateSession(t.Context(), conn(t), daemon.CreateSessionRequest{Workspace: t.TempDir(), Provider: profile})
	if err != nil {
		t.Fatal(err)
	}
	return created.ID
}

func TestWebhookCreationMissingGeneratedSecretStopsAfterOneEffect(t *testing.T) {
	profile := providerRoute(t, echoReply)
	id := newFaultSession(t, profile)
	enableExtension(t, conn(t), id, "webhooks")
	path := "/extensions/webhooks/hooks"
	proxy := mutateAcknowledgement(t, path, "", nil, func(body []byte) ([]byte, error) {
		var envelope map[string]json.RawMessage
		if err := json.Unmarshal(body, &envelope); err != nil {
			return nil, err
		}
		if _, present := envelope["secret"]; !present {
			return nil, errors.New("daemon did not generate a secret")
		}
		delete(envelope, "secret")
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
	// Creation installs the signature atomically even when its secret acknowledgment is lost.
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
		Resource struct {
			ETag  string `json:"etag"`
			Value struct {
				ID string `json:"id"`
			} `json:"value"`
		} `json:"resource"`
	}
	if err := json.Unmarshal(accepted, &original); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := daemon.DeleteWebhook(context.Background(), conn(t), original.Resource.Value.ID, original.Resource.ETag); err != nil {
			t.Error(err)
		}
	})
	listed, err := daemon.ListWebhooks(t.Context(), conn(t), id)
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, entry := range listed {
		if entry.Hook.Session == id && entry.Hook.Name == "missing-secret" {
			count++
			if entry.Hook.Header != "x-custom-signature" {
				t.Fatal("atomic signature configuration was lost")
			}
		}
	}
	if count != 1 {
		t.Fatalf("persisted %d hooks, want one", count)
	}
}

func TestUnknownReceiptReplaysOriginalCreationOnce(t *testing.T) {
	providerRoute(t, echoReply)
	// Default-changing tests finish before parallel bodies. These creations
	// send no turns and do not assert which provider the daemon selects.
	t.Parallel()
	workspace := t.TempDir()
	proxy := cutAcknowledgement(t, "/sessions", hideReceiptAcknowledgement)
	handle, err := daemon.NewCreation(daemon.CreateSessionRequest{Workspace: workspace})
	if err != nil {
		t.Fatal(err)
	}
	created, err := daemon.CreateSessionOperation(t.Context(), proxy.connection, handle)
	if err != nil {
		t.Fatal(err)
	}
	proxy.mu.Lock()
	responses := slices.Clone(proxy.responses)
	proxy.mu.Unlock()
	if len(responses) != 2 {
		t.Fatalf("expected the original PUT and one conditional retry, got %d", len(responses))
	}
	requests := operationRequests(proxy)
	if len(requests) != 4 || requests[0] != requests[2] || requests[1] != requests[3] {
		t.Fatalf("retry changed the original resource: %v", requests)
	}
	count := 0
	for _, session := range daemonSessions(t) {
		if session.Workspace == workspace {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("replay created %d sessions", count)
	}
	resolved, err := daemon.ResolveCreation(t.Context(), proxy.connection, handle)
	if err != nil || resolved.ID != created.ID {
		t.Fatalf("original creation: %+v %v", resolved, err)
	}
}

func TestQueuedPromptDeadlineCancelsOnlyItsOperation(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	released := false
	defer func() {
		if !released {
			close(release)
		}
	}()
	profile := providerRoute(t, func(request map[string]any) string {
		if lastUserText(request) == "active" {
			close(entered)
			<-release
		}
		return echoReply(request)
	})
	t.Parallel()
	id := newSession(t, t.TempDir())
	if _, err := daemon.NewChatClient(conn(t), id).Send(t.Context(), "active", nil); err != nil {
		t.Fatal(err)
	}
	select {
	case <-entered:
	case <-time.After(10 * time.Second):
		t.Fatal("active turn never started")
	}
	connection, attachErr := daemon.Attach(t.Context(), conn(t).Snapshot(), nil)
	if attachErr != nil {
		t.Fatal(attachErr)
	}
	counter := &submissionCounterTransport{next: connection.HTTPClient().Transport, accepted: make(chan struct{})}
	connection.HTTPClient().Transport = counter
	t.Cleanup(connection.HTTPClient().CloseIdleConnections)
	service := app.Service{Connect: func(context.Context) (*daemon.Connection, error) { return connection, nil }}
	finished := make(chan error, 1)
	go func() {
		_, err := service.RunPrompt(t.Context(), app.PromptOptions{SessionID: id, Prompt: "waiting", Timeout: 2 * time.Second})
		finished <- err
	}()
	select {
	case <-counter.accepted:
	case err := <-finished:
		t.Fatalf("prompt ended before durable acceptance: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("queued prompt was not admitted")
	}
	err := <-finished
	uncertain, ok := errors.AsType[*daemon.UncertainOutcomeError](err)
	if !ok || uncertain.Handle == nil || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("deadline lost operation identity: %v", err)
	}
	receipt, err := daemon.ResolveOperation(t.Context(), connection, uncertain.Handle)
	if err != nil || receipt.Delivery == nil || *receipt.Delivery != "cancelled" {
		t.Fatalf("queued receipt after deadline: %+v %v", receipt, err)
	}
	if counter.posts.Load() != 1 {
		t.Fatal("query recovery submitted another intent")
	}
	close(release)
	released = true
	waitIdle(t, id, profile, 1)
	receipt, err = daemon.ResolveOperation(t.Context(), connection, uncertain.Handle)
	if err != nil || receipt.Delivery == nil || *receipt.Delivery != "cancelled" {
		t.Fatalf("cancelled receipt after unrelated turn: %+v %v", receipt, err)
	}
	if counter.posts.Load() != 1 {
		t.Fatal("query recovery submitted another intent")
	}
	history, err := daemon.NewChatClient(conn(t), id).History(t.Context(), 0, 120)
	if err != nil {
		t.Fatal(err)
	}
	matched := 0
	for _, event := range history.Events {
		if event.Type == daemon.EventUser && event.OperationID == uncertain.Handle.ID() {
			matched++
		}
	}
	if matched != 0 {
		t.Fatalf("cancelled deadline operation delivered %d times", matched)
	}
}

// Count the real client's submissions while leaving its SSE stream unbuffered.
type submissionCounterTransport struct {
	next       http.RoundTripper
	posts      atomic.Int32
	accepted   chan struct{}
	acceptOnce sync.Once
}

func (transport *submissionCounterTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	if request.Method == http.MethodPut && strings.Contains(request.URL.Path, "/inputs/") {
		transport.posts.Add(1)
	}
	response, err := transport.next.RoundTrip(request)
	if err == nil && request.Method == http.MethodPut && strings.Contains(request.URL.Path, "/inputs/") && response.StatusCode == http.StatusAccepted {
		transport.acceptOnce.Do(func() { close(transport.accepted) })
	}
	return response, err
}
func (transport *submissionCounterTransport) CloseIdleConnections() {
	if closer, ok := transport.next.(interface{ CloseIdleConnections() }); ok {
		closer.CloseIdleConnections()
	}
}

func TestTUICreationRecoveryRetainsSelectedSession(t *testing.T) {
	profile := providerRoute(t, echoReply)
	// Default-changing tests finish before parallel bodies. These creations
	// send no turns and do not assert which provider the daemon selects.
	t.Parallel()
	initial := daemonSession(t, newFaultSession(t, profile))
	other := daemonSession(t, newFaultSession(t, profile))
	workspace := t.TempDir()
	proxy := cutAcknowledgement(t, "/sessions", unresolvedAcknowledgement)
	driver := driveTUIWithConnection(t, &initial, proxy.connection)
	t.Cleanup(func() { driver.App.Chat.Close() })
	uncertain := driver.Send(tui.FolderNewSessionMsg{Workspace: workspace})
	driver.Update(tui.FolderOpenSessionMsg{Session: other})
	recovery := driver.Update(uncertain)
	if recovery == nil {
		t.Fatal("navigation discarded uncertain creation recovery")
	}
	proxy.allowReceipt.Store(true)
	for _, recoveryRequest := range driver.results(recovery) {
		driver.Update(driver.Send(recoveryRequest))
	}
	if driver.App.ActiveSession == nil || driver.App.ActiveSession.ID != other.ID {
		t.Fatal("recovering older creation replaced the user's selected session")
	}
	count := 0
	for _, session := range driver.App.Sessions {
		if session.Workspace == workspace {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("navigation recovered %d created sessions", count)
	}
	proxy.mu.Lock()
	responses := slices.Clone(proxy.responses)
	proxy.mu.Unlock()
	var first struct {
		ID string `json:"id"`
	}
	var replay struct {
		Decision struct {
			SessionID  string `json:"session_id"`
			Admission  string `json:"admission"`
			HTTPStatus int    `json:"http_status"`
		} `json:"decision"`
	}
	if len(responses) != 2 || json.Unmarshal(responses[0], &first) != nil || first.ID == "" || json.Unmarshal(responses[1], &replay) != nil || replay.Decision.SessionID != first.ID || replay.Decision.Admission != "accepted" || replay.Decision.HTTPStatus != 201 {
		t.Fatalf("creation retry lost its original accepted decision: %d responses, identity=%q replay=%+v", len(responses), first.ID, replay.Decision)
	}
	if recovered, err := daemon.GetSession(t.Context(), conn(t), first.ID); err != nil || recovered.Workspace != workspace {
		t.Fatalf("recovery lost created session: %v", err)
	}
	count = 0
	for _, session := range daemonSessions(t) {
		if session.Workspace == workspace {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("creation uncertainty produced %d durable sessions", count)
	}
}

// Receipt fault tests also navigate sessions, whose event streams must remain live.
