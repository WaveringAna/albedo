//go:build unix

// Prompt scenarios: `albedo -p` sends one prompt, blocks until its turn ends,
// and prints only the final assistant text, so a script can pipe it.
package e2e

import (
	"context"
	"net/url"
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
	if err := daemon.SaveProvider(context.Background(), conn(t), profile, config.Settings{
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
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	profile := providerRoute(t, func(request map[string]any) string {
		select {
		case <-release:
		case <-time.After(10 * time.Second):
		}
		return echoReply(request)
	})

	started := time.Now()
	stdout, stderr, err := runCLI("-p", "stall", "--model", profile+"/fixture-model", "--timeout", "1s")
	if err == nil || stdout != "" || !strings.Contains(stderr, "timed out after 1s") {
		t.Fatalf("timed-out prompt: err=%v stdout=%q stderr=%q", err, stdout, stderr)
	}
	_, id, _ := strings.Cut(strings.TrimSpace(stderr), "the session is ")
	for {
		status, err := daemon.Request[struct {
			Idle bool `json:"idle"`
		}](context.Background(), conn(t), "/sessions/"+url.PathEscape(id)+"/status", nil)
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
	defer close(release)
	profile := providerRoute(t, func(request map[string]any) string {
		if lastUserText(request) == "other turn" {
			close(entered)
			<-release
		}
		return echoReply(request)
	})
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
	// Stop the session explicitly so this stalled fixture cannot leak into other tests.
	if _, err := client.Interrupt(t.Context()); err != nil {
		t.Fatal(err)
	}
	waitIdle(t, id, profile, 1)
}
