//go:build unix

// Prompt scenarios: `albedo -p` sends one prompt, blocks until its turn ends,
// and prints only the final assistant text, so a script can pipe it.
package e2e

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
)

// A new prompt runs in a fresh session on the model named provider/model, and
// stdout is exactly the reply; `albedo models` lists that same spelling.
func TestPromptPrintsTheFinalReplyFromTheNamedModel(t *testing.T) {
	profile := providerRoute(t, echoReply)
	model := profile + "/fixture-model"
	if listed := cli(t, "models"); !strings.Contains(listed, model+"\n") {
		t.Fatalf("albedo models does not list %s:\n%s", model, listed)
	}

	stdout := cli(t, "-p", "print me", "--model", model)
	if stdout != "echo: print me\n" {
		t.Fatalf("albedo -p printed %q", stdout)
	}
	if got := len(suite.provider.requests(profile)); got != 1 {
		t.Fatalf("provider %s saw %d requests, want 1", profile, got)
	}
}

// --model on an existing session moves only that session: the turn reaches
// the other provider, and new sessions still default to the active one.
func TestPromptToASessionSwitchesItsModelWithoutChangingTheDefault(t *testing.T) {
	other := "PromptSwitchTarget"
	if err := suite.provider.addProfile(other, echoReply); err != nil {
		t.Fatal(err)
	}
	profile := providerRoute(t, echoReply)
	id := newSession(t, t.TempDir())

	stdout := cli(t, "--prompt", "switch", "--session", id, "--model", other+"/fixture-model")
	if stdout != "echo: switch\n" {
		t.Fatalf("albedo -p -s printed %q", stdout)
	}
	if len(suite.provider.requests(other)) != 1 || len(suite.provider.requests(profile)) != 0 {
		t.Fatalf("turn went to the wrong provider: %s=%d %s=%d", other,
			len(suite.provider.requests(other)), profile, len(suite.provider.requests(profile)))
	}
	if session := daemonSession(t, id); session.Provider != other {
		t.Fatalf("session provider is %q, want %q", session.Provider, other)
	}
	profiles, err := daemon.ProviderProfiles(context.Background(), conn(t))
	if err != nil || profiles.Active != profile {
		t.Fatalf("default provider became %q (%v), want %q", profiles.Active, err, profile)
	}
}

// A turn that fails must end the command with the failure, not hang or print
// an empty reply; a model no provider offers fails before any session exists.
func TestPromptReportsAFailedTurnAndAnUnknownModel(t *testing.T) {
	profile := t.Name()
	if err := saveAndSelectProvider(context.Background(), conn(t), profile, config.Settings{
		Extension: "openai",
		BaseURL:   suite.provider.server.URL + "/t/missing",
		APIKey:    "fixture-key",
		Model:     "fixture-model",
		Protocol:  "chat_completions",
	}); err != nil {
		t.Fatal(err)
	}

	stdout, stderr, err := runCLI("-p", "fail", "--model", profile+"/fixture-model")
	if err == nil || stdout != "" || !strings.Contains(stderr, "404") {
		t.Fatalf("failed turn: err=%v stdout=%q stderr=%q", err, stdout, stderr)
	}

	before := len(daemonSessions(t))
	_, stderr, err = runCLI("-p", "never sent", "--model", "no-such-model")
	if err == nil || !strings.Contains(stderr, "albedo models") {
		t.Fatalf("unknown model: err=%v stderr=%q", err, stderr)
	}
	if after := len(daemonSessions(t)); after != before {
		t.Fatalf("an unknown model still created a session (%d -> %d)", before, after)
	}
}

// --timeout fails the command once it passes and stops the turn it started:
// the session is idle long before the stalled provider would have answered.
func TestPromptTimeoutStopsTheTurn(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	t.Cleanup(func() { close(release) })
	profile := providerRoute(t, func(request map[string]any) string {
		if lastUserText(request) == "stall" {
			close(entered)
			select {
			case <-release:
			case <-time.After(10 * time.Second):
			}
		}
		return echoReply(request)
	})
	// The deadline tests turn cancellation, not session creation or kernel boot.
	session := newSession(t, t.TempDir())
	cli(t, "-p", "warm the timeout session", "--session", session)
	waitIdle(t, session, profile, 1)

	started := time.Now()
	stdout, stderr, err := runCLI("-p", "stall", "--session", session, "--timeout", "1s")
	if err == nil || stdout != "" || !strings.Contains(stderr, "timed out after 1s") {
		t.Fatalf("timed-out prompt: err=%v stdout=%q stderr=%q", err, stdout, stderr)
	}
	select {
	case <-entered:
	default:
		t.Fatal("the deadline expired before the stalled turn reached the provider")
	}
	_, id, _ := strings.Cut(strings.TrimSpace(stderr), "the session is ")
	if id != session {
		t.Fatalf("timeout reported session %q, want %q", id, session)
	}
	for {
		status, err := daemon.NewChatClient(conn(t), id).GetStatus(context.Background())
		if err != nil {
			t.Fatalf("status of %q: %v", id, err)
		}
		if status.Idle {
			break
		}
		if time.Since(started) > 6*time.Second {
			t.Fatal("the timed-out turn is still running")
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// Cancellation while queued must leave the already running turn alone.
func TestPromptTimeoutWhileQueuedDoesNotInterruptAnotherTurn(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	releaseClosed := false
	defer func() {
		if !releaseClosed {
			close(release)
		}
	}()
	profile := providerRoute(t, func(request map[string]any) string {
		if lastUserText(request) == "other turn" {
			close(entered)
			<-release
		}
		return echoReply(request)
	})
	t.Parallel()
	id := newSession(t, t.TempDir())
	client := daemon.NewChatClient(conn(t), id)
	if _, err := client.Send(t.Context(), "other turn", nil); err != nil {
		t.Fatal(err)
	}
	select {
	case <-entered:
	case <-time.After(10 * time.Second):
		t.Fatal("other turn never started")
	}
	stdout, stderr, err := runCLI("--prompt", "queued turn", "--session", id, "--timeout", "1s")
	if err == nil || stdout != "" || !strings.Contains(stderr, "timed out after 1s") {
		t.Fatalf("queued timeout: %v %q %q", err, stdout, stderr)
	}
	status, statusErr := client.GetStatus(t.Context())
	if statusErr != nil || status.Idle {
		t.Fatalf("queued cancellation stopped the other turn: %+v %v", status, statusErr)
	}
	if !strings.Contains(stderr, "queued submission cancelled") || strings.Contains(stderr, "stopped") {
		t.Fatalf("incorrect cancellation report: %s", stderr)
	}
	_, identity, _ := strings.Cut(stderr, "operation ")
	inputID, _, _ := strings.Cut(identity, " can be queried")
	receipt, receiptErr := daemon.GetInput(t.Context(), conn(t), id, inputID)
	if receiptErr != nil || receipt.Admission != "accepted" || receipt.Delivery == nil || *receipt.Delivery != "cancelled" || receipt.Turn != nil {
		t.Fatalf("timed call did not cancel an admitted queued input: %+v, %v", receipt, receiptErr)
	}
	close(release)
	releaseClosed = true
	waitIdle(t, id, profile, 1)
	if got := len(suite.provider.requests(profile)); got != 1 {
		t.Fatalf("cancelled queued prompt still ran: %d requests", got)
	}
	missing, err := client.PrepareTurn("never submitted", nil, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.CancelSubmission(t.Context(), missing.ID())
	if failure, ok := errors.AsType[*daemon.APIError](err); !ok || failure.StatusCode != 404 {
		t.Fatalf("missing cancellation: %v", err)
	}
}

// Both identified submissions contribute to the same next turn. Targeted
// cancellation must leave that shared turn running, including anonymous input.
func TestSubmissionCancellationLeavesSharedRunningTurn(t *testing.T) {
	firstEntered, firstRelease := make(chan struct{}), make(chan struct{})
	sharedEntered, sharedRelease := make(chan struct{}), make(chan struct{})
	firstReleased, sharedReleased := false, false
	defer func() {
		if !firstReleased {
			close(firstRelease)
		}
		if !sharedReleased {
			close(sharedRelease)
		}
	}()
	profile := providerRoute(t, func(request map[string]any) string {
		if lastUserText(request) == "blocking turn" {
			close(firstEntered)
			<-firstRelease
		} else {
			close(sharedEntered)
			<-sharedRelease
		}
		return echoReply(request)
	})
	id := newSession(t, t.TempDir())
	client := daemon.NewChatClient(conn(t), id)
	if _, err := client.Send(t.Context(), "blocking turn", nil); err != nil {
		t.Fatal(err)
	}
	select {
	case <-firstEntered:
	case <-time.After(10 * time.Second):
		t.Fatal("first turn never started")
	}
	shared, err := client.Send(t.Context(), "identified contribution", nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.Send(t.Context(), "anonymous contribution", nil); err != nil {
		t.Fatal(err)
	}
	queued, err := client.Send(t.Context(), "cancel this queued contribution", nil)
	if err != nil {
		t.Fatal(err)
	}
	outcome, cancelErr := client.CancelSubmission(t.Context(), queued.OperationID)
	if cancelErr != nil || outcome != "cancelled_queued" {
		t.Fatalf("queued cancellation = %q %v", outcome, cancelErr)
	}
	outcome, cancelErr = client.CancelSubmission(t.Context(), queued.OperationID)
	if cancelErr != nil || outcome != "not_pending" {
		t.Fatalf("repeated queued cancellation = %q %v", outcome, cancelErr)
	}
	close(firstRelease)
	firstReleased = true
	select {
	case <-sharedEntered:
	case <-time.After(10 * time.Second):
		t.Fatal("shared turn never started")
	}
	for range 2 {
		outcome, err := client.CancelSubmission(t.Context(), shared.OperationID)
		if err != nil || outcome != "shared_running" {
			t.Fatalf("shared cancellation = %q, %v", outcome, err)
		}
	}
	status, err := client.GetStatus(t.Context())
	if err != nil || status.Idle {
		t.Fatalf("shared turn stopped: %+v %v", status, err)
	}
	close(sharedRelease)
	sharedReleased = true
	waitIdle(t, id, profile, 2)
	requests := suite.provider.requests(profile)
	encoded, marshalErr := json.Marshal(requests[1])
	if marshalErr != nil || strings.Contains(string(encoded), "cancel this queued contribution") || !strings.Contains(string(encoded), "identified contribution") || !strings.Contains(string(encoded), "anonymous contribution") {
		t.Fatalf("queued cancellation damaged sibling inputs: %s %v", encoded, marshalErr)
	}
}

// Cancellation races turn admission and completion. Once that target settles,
// repeating cancellation cannot stop a later exclusively owned turn.
func TestSubmissionCancellationRacesStartAndCompletion(t *testing.T) {
	firstEntered, firstRelease := make(chan struct{}), make(chan struct{})
	laterEntered, laterRelease := make(chan struct{}), make(chan struct{})
	firstReleased, laterReleased := false, false
	defer func() {
		if !firstReleased {
			close(firstRelease)
		}
		if !laterReleased {
			close(laterRelease)
		}
	}()
	profile := providerRoute(t, func(request map[string]any) string {
		switch lastUserText(request) {
		case "hold first turn":
			close(firstEntered)
			<-firstRelease
		case "hold later turn":
			close(laterEntered)
			<-laterRelease
		}
		return echoReply(request)
	})
	id := newSession(t, t.TempDir())
	client := daemon.NewChatClient(conn(t), id)
	if _, err := client.Send(t.Context(), "hold first turn", nil); err != nil {
		t.Fatal(err)
	}
	select {
	case <-firstEntered:
	case <-time.After(10 * time.Second):
		t.Fatal("first turn never started")
	}
	target, err := client.Send(t.Context(), "short target turn", nil)
	if err != nil {
		t.Fatal(err)
	}
	submissionID := target.OperationID
	type cancellation struct {
		err     error
		outcome string
	}
	result := make(chan cancellation, 1)
	start := make(chan struct{})
	go func() {
		<-start
		outcome, err := client.CancelSubmission(t.Context(), submissionID)
		result <- cancellation{err: err, outcome: outcome}
	}()
	close(start)
	close(firstRelease)
	firstReleased = true
	var cancelled cancellation
	select {
	case cancelled = <-result:
	case <-time.After(10 * time.Second):
		t.Fatal("racing cancellation did not return")
	}
	if cancelled.err != nil {
		t.Fatal(cancelled.err)
	}
	switch cancelled.outcome {
	case "cancelled_queued", "interrupt_requested", "not_pending":
	default:
		t.Fatalf("unexpected racing cancellation outcome %q", cancelled.outcome)
	}
	waitIdle(t, id, profile, 1)
	if _, err := client.Send(t.Context(), "hold later turn", nil); err != nil {
		t.Fatal(err)
	}
	select {
	case <-laterEntered:
	case <-time.After(10 * time.Second):
		t.Fatal("later turn never started")
	}
	outcome, err := client.CancelSubmission(t.Context(), submissionID)
	if err != nil || outcome != "not_pending" {
		t.Fatalf("settled target cancellation = %q %v", outcome, err)
	}
	status, err := client.GetStatus(t.Context())
	if err != nil || status.Idle {
		t.Fatalf("old cancellation stopped a later turn: %+v %v", status, err)
	}
	close(laterRelease)
	laterReleased = true
	waitIdle(t, id, profile, 2)
}
