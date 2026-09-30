//go:build unix

// CLI scenarios: the built binary, driven as a user would, against the suite's
// one real daemon. Each scenario registers its own provider route and works in
// its own workspace; assertions read what a user observes -- command output,
// the session listing, the transcript -- plus what the provider recorded.
package e2e

import (
	"context"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
)

// A session created by `albedo new` must be listed by `sessions --json` with
// its workspace, model, and active provider, and `resume` must resolve both
// the full id and a prefix back to it. This only holds when new, sessions,
// resume, and the daemon's session registry agree.
func TestNewSessionIsListedAndResumes(t *testing.T) {
	profile := providerRoute(t, echoReply)
	workspace := t.TempDir()
	created := cliSession(t, workspace)

	listing := cli(t, "sessions", "--json")
	var sessions []daemon.Session
	if err := json.Unmarshal([]byte(listing), &sessions); err != nil {
		t.Fatalf("sessions --json: %v\n%s", err, listing)
	}
	var listed *daemon.Session
	for i := range sessions {
		if sessions[i].ID == created {
			listed = &sessions[i]
		}
	}
	if listed == nil {
		t.Fatalf("session %s is missing from `albedo sessions --json`:\n%s", created, listing)
	}
	if !samePath(listed.Workspace, workspace) {
		t.Errorf("session workspace is %q, created in %q", listed.Workspace, workspace)
	}
	if listed.Provider != profile {
		t.Errorf("session provider is %q, active profile is %q", listed.Provider, profile)
	}
	if listed.Model != "fixture-model" {
		t.Errorf("session model is %q, want the configured fixture-model", listed.Model)
	}

	var resumed struct {
		Session string `json:"session"`
	}
	if err := json.Unmarshal([]byte(cli(t, "resume", created)), &resumed); err != nil || resumed.Session != created {
		t.Fatalf("albedo resume by id: session=%q err=%v", resumed.Session, err)
	}
	if err := json.Unmarshal([]byte(cli(t, "resume", created[:8])), &resumed); err != nil || resumed.Session != created {
		t.Fatalf("albedo resume by prefix: session=%q err=%v", resumed.Session, err)
	}
}

// A prompt sent with `albedo send` must come back as assistant text: the
// provider configuration reaches the daemon's upstream client, the turn runs,
// and the committed transcript records the reply. The provider's recorded
// request is the proof the daemon actually called the model.
func TestSendTurnReachesProviderAndTranscript(t *testing.T) {
	t.Parallel()
	profile := providerRoute(t, echoReply)
	workspace := t.TempDir()
	id := newSession(t, workspace)

	prompt := "e2e turn through the cli"
	var sent daemon.SendResult
	if err := json.Unmarshal([]byte(cli(t, "send", id, prompt)), &sent); err != nil || !sent.OK {
		t.Fatalf("albedo send: ok=%v err=%v", sent.OK, err)
	}

	waitIdle(t, id, profile, 1)
	reply := strings.Join(eventText(streamSnapshot(t, id), "message"), "\n")
	if !strings.Contains(reply, "echo: "+prompt) {
		t.Fatalf("assistant reply is missing from the transcript; got:\n%s", reply)
	}

	requests := suite.provider.requests(profile)
	if len(requests) == 0 {
		t.Fatalf("provider profile %s received no request", profile)
	}
	request := requests[0]
	if request["model"] != "fixture-model" {
		t.Errorf("provider saw model %v, config specifies fixture-model", request["model"])
	}
	if request["authorization"] != "Bearer fixture-key" {
		t.Errorf("provider saw authorization %v", request["authorization"])
	}
	body, _ := request["body"].(map[string]any)
	if forwarded := lastUserText(body); !strings.Contains(forwarded, prompt) {
		t.Errorf("provider request does not carry the prompt %q: %q", prompt, forwarded)
	}
}

// A turn driven through daemon.ChatClient -- the path the TUI takes -- must
// stream the assistant's reply as message events and settle to idle. This is
// the real client: agent-scoped routes, SSE replay, and status polling against
// the live daemon.
func TestChatClientTurnStreamsAndSettles(t *testing.T) {
	t.Parallel()
	profile := providerRoute(t, echoReply)
	workspace := t.TempDir()
	id := newSession(t, workspace)

	client := daemon.NewChatClient(conn(t), id)
	ctx := t.Context()

	events := make(chan daemon.StreamEvent, 128)
	streamErr := make(chan error, 1)
	go func() {
		streamErr <- client.Stream(ctx, 0, func(event daemon.StreamEvent) error {
			select {
			case events <- event:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		})
	}()

	prompt := "e2e turn through the chat client"
	if _, err := client.Send(ctx, prompt, nil); err != nil {
		t.Fatalf("chat client send: %v", err)
	}

	var reply string
	deadline := time.After(30 * time.Second)
	for reply == "" {
		select {
		case event := <-events:
			if event.Type == daemon.EventMessage {
				reply = event.Text
			}
		case err := <-streamErr:
			t.Fatalf("stream ended before the reply: %v", err)
		case <-deadline:
			t.Fatalf("no assistant message streamed within 30s")
		}
	}
	if !strings.Contains(reply, "echo: "+prompt) {
		t.Fatalf("streamed reply %q does not carry the scripted echo", reply)
	}

	waitIdle(t, id, profile, 1)
	status, err := client.GetStatus(context.Background())
	if err != nil {
		t.Fatalf("chat client status: %v", err)
	}
	if status.Running || !status.Idle {
		t.Fatalf("session is not idle after the turn: %+v", status)
	}
	if requests := suite.provider.requests(profile); len(requests) == 0 {
		t.Fatalf("provider profile %s received no request", profile)
	}
}

// Sending to a session that does not exist must fail loudly rather than queue
// a prompt into nothing.
func TestSendToUnknownSessionFails(t *testing.T) {
	t.Parallel()
	stdout, stderr, err := runCLI("send", "e2e-no-such-session", "hello")
	if err == nil {
		t.Fatalf("albedo send to an unknown session exited 0: %s", stdout)
	}
	if !strings.Contains(stderr, "not found") {
		t.Fatalf("expected a not-found diagnostic, got stderr: %s", stderr)
	}
}

// samePath compares two paths, tolerating macOS /var -> /private/var symlinks.
func samePath(a, b string) bool {
	if filepath.Clean(a) == filepath.Clean(b) {
		return true
	}
	resolvedA, errA := filepath.EvalSymlinks(a)
	resolvedB, errB := filepath.EvalSymlinks(b)
	return errA == nil && errB == nil && resolvedA == resolvedB
}
