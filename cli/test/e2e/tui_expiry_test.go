//go:build unix

// Expired receipts stop recovery without losing the original intent. The real
// daemon admits each request before the proxy discards its acknowledgement.
package e2e

import (
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui"
	tea "charm.land/bubbletea/v2"
)

func operationRequests(proxy *acknowledgementProxy) []string {
	proxy.mu.Lock()
	defer proxy.mu.Unlock()
	return slices.DeleteFunc(slices.Clone(proxy.requests), func(request string) bool {
		if strings.Contains(request, "/visits/") {
			return true
		}
		if strings.HasPrefix(request, "PUT /sessions/") {
			return false
		}
		if strings.HasPrefix(request, "GET /sessions/") {
			return !slices.Contains(proxy.requests, "PUT "+strings.TrimPrefix(request, "GET "))
		}
		return true
	})
}

func TestTUIExpiredSubmissionsRemainUnresolvedAcrossNavigation(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	released := false
	defer func() {
		if !released {
			close(release)
		}
	}()
	var enteredOnce sync.Once
	profile := providerRoute(t, func(request map[string]any) string {
		if lastUserText(request) == "hold expired submissions" {
			enteredOnce.Do(func() { close(entered) })
			<-release
		}
		return echoReply(request)
	})
	session := daemonSession(t, newSession(t, t.TempDir()))
	other := daemonSession(t, newSession(t, t.TempDir()))
	if _, err := daemon.NewChatClient(conn(t), session.ID).Send(t.Context(), "hold expired submissions", nil); err != nil {
		t.Fatal(err)
	}
	select {
	case <-entered:
	case <-time.After(10 * time.Second):
		t.Fatal("active turn never started")
	}
	proxy := cutAcknowledgement(t, "/sessions/"+session.ID+"/inputs/", expiredAcknowledgement)
	driver := driveTUIWithConnection(t, &session, proxy.connection)
	t.Cleanup(func() { driver.App.Chat.Close() })
	driver.Update(tea.WindowSizeMsg{Width: 120, Height: 100})
	driver.connected()
	var handles []*daemon.OperationHandle
	for index := 0; index < tui.MaxPendingUsers+1; index++ {
		prompt := fmt.Sprintf("unresolved user %d", index)
		driver.App.Chat.TextArea.SetValue(prompt)
		if index == 0 {
			driver.App.Chat.AttachedImage = &daemon.ImageAttachment{Data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC", ImageMetadata: daemon.ImageMetadata{MimeType: daemon.ImagePNG, Width: 1, Height: 1, Bytes: 69}}
		}
		var sent tui.ChatTurnSentMsg
		for _, message := range driver.results(driver.Update(tea.KeyPressMsg{Code: tea.KeyEnter})) {
			if result, ok := message.(tui.ChatTurnSentMsg); ok {
				sent = result
			}
			if cmd := driver.Update(message); cmd != nil {
				if _, ok := message.(tui.ChatTurnSentMsg); ok {
					t.Fatalf("expired submission scheduled recovery: %T", message)
				}
			}
		}
		uncertainty, ok := errors.AsType[*daemon.UncertainOutcomeError](sent.Err)
		if !ok || uncertainty.Handle != sent.Handle || !daemon.IsOperationExpired(sent.Err) || sent.Handle == nil {
			t.Fatalf("expired outcome lost original handle: %+v", sent)
		}
		handles = append(handles, sent.Handle)
	}
	driver.App.Chat.TextArea.SetValue(".")
	for _, message := range driver.results(driver.Update(tea.KeyPressMsg{Code: tea.KeyEnter})) {
		if sent, ok := message.(tui.ChatTurnSentMsg); ok {
			if sent.Handle == nil || !daemon.IsOperationExpired(sent.Err) {
				t.Fatalf("expired continuation: %+v", sent)
			}
			handles = append(handles, sent.Handle)
		}
		if cmd := driver.Update(message); cmd != nil {
			if _, ok := message.(tui.ChatTurnSentMsg); ok {
				t.Fatal("expired continuation scheduled recovery")
			}
		}
	}
	if len(handles) != tui.MaxPendingUsers+2 {
		t.Fatal("expired turns consumed pending capacity")
	}
	before := operationRequests(proxy)
	for _, handle := range handles {
		if cmd := driver.Update(tui.ChatOperationPollMsg{SessionID: session.ID, Generation: driver.App.Chat.Generation, Handle: handle}); cmd != nil {
			t.Fatal("expired operation resumed polling")
		}
	}
	driver.Update(tui.FolderOpenSessionMsg{Session: other})
	for _, message := range driver.results(driver.Update(tui.FolderOpenSessionMsg{Session: session})) {
		driver.Update(message)
	}
	driver.Update(tea.WindowSizeMsg{Width: 120, Height: 100})
	view := driver.View()
	for _, handle := range handles {
		if !strings.Contains(view, handle.ID()) {
			t.Fatalf("navigation lost unresolved identity %s:\n%s", handle.ID(), view)
		}
	}
	if after := operationRequests(proxy); !slices.Equal(before, after) {
		t.Fatalf("navigation resumed recovery: before=%v after=%v", before, after)
	}
	if len(before) != 2*len(handles) {
		t.Fatalf("expiry retried HTTP admission: %v", before)
	}
	// A durable event can still reconcile an outcome whose receipt has expired.
	close(release)
	released = true
	waitIdle(t, session.ID, profile, 2)
	history, err := daemon.NewChatClient(conn(t), session.ID).History(t.Context(), 0, 120)
	if err != nil {
		t.Fatal(err)
	}
	matched := false
	for _, event := range history.Events {
		if event.Type == daemon.EventUser && event.OperationID == handles[0].ID() {
			matched = true
			if event.Image == nil || event.Image.Width != 1 || event.Image.Height != 1 {
				t.Fatalf("expired image metadata lost: %+v", event)
			}
			driver.Update(tui.ChatStreamEventMsg{SessionID: session.ID, Generation: driver.App.Chat.Generation, Event: event})
		}
	}
	if !matched {
		for _, event := range history.Events {
			t.Logf("durable event %s input=%s image=%v", event.Type, event.OperationID, event.Image != nil)
		}
		t.Fatal("durable history did not retain the expired input identity")
	}
	if strings.Contains(driver.View(), handles[0].ID()) {
		t.Fatalf("durable user echo did not reconcile expired row:\n%s", driver.View())
	}

}

func TestTUICreationExpiryStopsRecoveryWithoutSwitchingSession(t *testing.T) {
	providerRoute(t, echoReply)
	initial := daemonSession(t, newSession(t, t.TempDir()))
	other := daemonSession(t, newSession(t, t.TempDir()))
	proxy := cutAcknowledgement(t, "/sessions", unresolvedAcknowledgement)
	driver := driveTUIWithConnection(t, &initial, proxy.connection)
	t.Cleanup(func() { driver.App.Chat.Close() })
	uncertain := driver.Send(tui.FolderNewSessionMsg{Workspace: t.TempDir()})
	driver.Update(tui.FolderOpenSessionMsg{Session: other})
	recovery := driver.Update(uncertain)
	if recovery == nil {
		t.Fatal("uncertain creation lost recovery")
	}
	proxy.allowReceipt.Store(true)
	proxy.expireReceipt.Store(true)
	var tick tea.Msg
	for _, message := range driver.results(recovery) {
		tick = message
		response := driver.Send(message)
		if cmd := driver.Update(response); cmd != nil {
			t.Fatal("expired creation scheduled further recovery")
		}
	}
	if driver.App.ActiveSession.ID != other.ID || !strings.Contains(driver.View(), "expired") {
		t.Fatalf("creation expiry switched session or lost notice:\n%s", driver.View())
	}
	before := operationRequests(proxy)
	operationID := strings.TrimPrefix(before[len(before)-1], "GET /sessions/")
	if !strings.Contains(driver.View(), operationID) {
		t.Fatal("expired creation notice lost its operation identity")
	}
	if tick == nil || driver.Update(tick) != nil {
		t.Fatal("scheduled creation tick restarted expired lookup")
	}
	if after := operationRequests(proxy); !slices.Equal(before, after) {
		t.Fatal("creation expiry resumed HTTP recovery")
	}
}

func TestTUIRejectedSubmissionRestoresPromptAndImage(t *testing.T) {
	providerRoute(t, echoReply)
	driver := newTUIDriver(t)
	t.Cleanup(func() { driver.App.Chat.Close() })
	driver.connected()
	image := &daemon.ImageAttachment{Data: "invalid", ImageMetadata: daemon.ImageMetadata{MimeType: daemon.ImagePNG, Width: 1, Height: 1, Bytes: 1}}
	driver.App.Chat.AttachedImage = image
	driver.App.Chat.TextArea.SetValue("restore this rejected image")
	var sent tui.ChatTurnSentMsg
	for _, message := range driver.results(driver.Update(tea.KeyPressMsg{Code: tea.KeyEnter})) {
		if result, ok := message.(tui.ChatTurnSentMsg); ok {
			sent = result
		}
		driver.Update(message)
	}
	api, ok := errors.AsType[*daemon.APIError](sent.Err)
	if !ok || api.StatusCode != http.StatusBadRequest || sent.Handle == nil {
		t.Fatalf("real daemon did not reject image: %+v", sent)
	}
	if driver.App.Chat.TextArea.Value() != sent.Prompt || driver.App.Chat.AttachedImage != image {
		t.Fatal("rejection lost prompt or attachment")
	}
	// A following valid submission demonstrates that the rejected row left no pending intent.
	driver.App.Chat.AttachedImage = nil
	driver.App.Chat.TextArea.SetValue("valid after rejection")
	for _, message := range driver.results(driver.Update(tea.KeyPressMsg{Code: tea.KeyEnter})) {
		if result, ok := message.(tui.ChatTurnSentMsg); ok && result.Err != nil {
			t.Fatal(result.Err)
		}
	}
}
