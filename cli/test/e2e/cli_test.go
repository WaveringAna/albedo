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
	"slices"
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
)

func listedSessionPrefix(t *testing.T, id string) string {
	t.Helper()
	for line := range strings.SplitSeq(cli(t, "sessions"), "\n") {
		fields := strings.Fields(line)
		if len(fields) > 0 && len(fields[0]) >= 8 && strings.HasPrefix(id, fields[0]) {
			return fields[0]
		}
	}
	t.Fatalf("session listing omitted %s", id)
	return ""
}

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
	if err := json.Unmarshal([]byte(cli(t, "resume", listedSessionPrefix(t, created))), &resumed); err != nil || resumed.Session != created {
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
	reply := strings.Join(eventText(durableHistorySnapshot(t, id), "message"), "\n")
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

// `albedo sessions` prints shortened IDs, so send and stop must accept them the
// way resume does.
func TestSendAndStopAcceptAShortenedSessionID(t *testing.T) {
	t.Parallel()
	profile := providerRoute(t, echoReply)
	id := newSession(t, t.TempDir())
	prefix := listedSessionPrefix(t, id)

	var sent daemon.SendResult
	if err := json.Unmarshal([]byte(cli(t, "send", prefix, "short id")), &sent); err != nil || !sent.OK {
		t.Fatalf("albedo send by prefix: ok=%v err=%v", sent.OK, err)
	}
	waitIdle(t, id, profile, 1)
	cli(t, "stop", prefix)

	if reply := cli(t, "--prompt", "by prefix", "--session", prefix); !strings.Contains(reply, "echo: by prefix") {
		t.Fatalf("albedo --prompt --session by prefix did not reach the session: %s", reply)
	}
}

// Another agent drives a session with `sessions send` and `sessions read`: the
// newest turns come back as text or JSON, and a count of one leaves the older
// turn out.
func TestSessionsSendAndRead(t *testing.T) {
	t.Parallel()
	profile := providerRoute(t, echoReply)
	id := newSession(t, t.TempDir())
	prefix := listedSessionPrefix(t, id)

	for i, prompt := range []string{"first question", "second question"} {
		var sent daemon.SendResult
		if err := json.Unmarshal([]byte(cli(t, "sessions", "send", prefix, prompt)), &sent); err != nil || !sent.OK {
			t.Fatalf("albedo sessions send %q: ok=%v err=%v", prompt, sent.OK, err)
		}
		waitIdle(t, id, profile, i+1)
	}

	latest := cli(t, "sessions", "read", prefix)
	if !strings.Contains(latest, "[user] second question") || !strings.Contains(latest, "[assistant] echo: second question") {
		t.Fatalf("read of the newest turn is missing it:\n%s", latest)
	}
	if strings.Contains(latest, "first question") {
		t.Fatalf("read of one turn includes an older one:\n%s", latest)
	}
	both := cli(t, "sessions", "read", prefix, "2")
	if !strings.Contains(both, "[user] first question") || !strings.Contains(both, "[assistant] echo: second question") {
		t.Fatalf("read of two turns is missing one:\n%s", both)
	}

	var parsed struct {
		Session string `json:"session"`
		Running bool   `json:"running"`
		Events  []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"events"`
	}
	if err := json.Unmarshal([]byte(cli(t, "sessions", "read", id, "1", "--json")), &parsed); err != nil || parsed.Session != id || parsed.Running || len(parsed.Events) == 0 {
		t.Fatalf("read --json: %+v err=%v", parsed, err)
	}

	if _, stderr, err := runCLI("sessions", "read", id, "0"); err == nil || !strings.Contains(stderr, "positive number") {
		t.Fatalf("read with zero turns: err=%v stderr=%s", err, stderr)
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
	if !strings.Contains(stderr, "no session matches") {
		t.Fatalf("expected a no-match diagnostic, got stderr: %s", stderr)
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

// Session deletion requires approval before it reaches the daemon.
func TestCLISessionDeletionRequiresConfirmation(t *testing.T) {
	providerRoute(t, echoReply)
	id := newSession(t, t.TempDir())
	stdout, stderr, err := runCLI("storage", "prune", "--session", id)
	if err == nil || !strings.Contains(stdout, "Permanently delete session "+id) || !strings.Contains(stderr, "no files have been removed") {
		t.Fatalf("unconfirmed deletion: %v %q %q", err, stdout, stderr)
	}
	if daemonSession(t, id).ID != id {
		t.Fatal("unconfirmed session deletion mutated daemon")
	}
	cli(t, "storage", "prune", "--session", id, "--yes")
	if sessions := daemonSessions(t); slices.ContainsFunc(sessions, func(session daemon.Session) bool { return session.ID == id }) {
		t.Fatal("confirmed session was not deleted")
	}
}
