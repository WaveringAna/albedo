// A ChatClient built before a real daemon restart must send another turn via
// its refreshed connection without losing the first turn's transcript. A fake
// daemon cannot exercise process lifetime or on-disk session persistence.
package e2e

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
)

// restartDaemon replaces the suite daemon under the same hermetic home and
// records its new pid for later scenarios.
func restartDaemon(t *testing.T) daemon.ConnectionSnapshot {
	t.Helper()
	old := suite.daemonPID

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if _, err := daemon.Request[map[string]any](ctx, conn(t), "/shutdown", map[string]any{}); err != nil {
		t.Fatalf("shutdown request: %v", err)
	}
	if !awaitExit(old, 15*time.Second) {
		t.Fatalf("daemon %d did not exit after shutdown", old)
	}

	if _, stderr, err := runCLI("sessions"); err != nil {
		t.Fatalf("rebooting the daemon: %v\n%s", err, stderr)
	}
	deadline := time.Now().Add(2 * time.Minute)
	for {
		snap, err := readDaemonSnapshot(suite.home)
		if err == nil && snap.Pid != old {
			suite.daemonPID = snap.Pid
			return snap
		}
		if time.Now().After(deadline) {
			t.Fatalf("no daemon other than %d published daemon.json after the restart", old)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// TestChatClientSendReconnectsAfterDaemonRestart sends two turns through the
// same client and session, with a real restart between them.
func TestChatClientSendReconnectsAfterDaemonRestart(t *testing.T) {
	profile := providerRoute(t, echoReply)
	workspace := t.TempDir()
	id := newSession(t, workspace)

	// The client exists before the restart and is the only thing this test
	// uses afterwards; a client created after the reboot would prove nothing.
	shared := conn(t)
	client := daemon.NewChatClient(daemon.ChatClientOptions{Conn: shared, AgentID: id})

	prompt1 := "turn before the restart"
	if _, err := client.Send(context.Background(), prompt1, nil); err != nil {
		t.Fatalf("first send: %v", err)
	}
	waitIdle(t, id)

	oldSnap := shared.Snapshot()
	snap := restartDaemon(t)

	prompt2 := "turn after the restart"
	sent, err := client.Send(context.Background(), prompt2, nil)
	if err != nil || sent == nil || !sent.OK {
		t.Fatalf("second send through the same client after the restart: ok=%v err=%v", sent != nil && sent.OK, err)
	}
	waitIdle(t, id)

	// The shared connection must now describe the restarted daemon, not the
	// one it was built on.
	if shared.Pid() != snap.Pid {
		t.Errorf("connection pid is %d, restarted daemon is %d", shared.Pid(), snap.Pid)
	}
	if shared.Token() != snap.Token {
		t.Errorf("connection token is not the restarted daemon's")
	}
	if want := fmt.Sprintf("http://127.0.0.1:%d", snap.Port); shared.BaseURL() != want {
		t.Errorf("connection base url is %s, want %s", shared.BaseURL(), want)
	}
	if shared.Token() == oldSnap.Token {
		t.Errorf("the token never changed, so this run did not exercise a real restart")
	}

	// Both turns crossed the whole stack to the provider.
	requests := suite.provider.requests(profile)
	if len(requests) < 2 {
		t.Fatalf("provider profile %s saw %d requests, want one per turn", profile, len(requests))
	}
	body, _ := requests[0]["body"].(map[string]any)
	if forwarded := lastUserText(body); !strings.Contains(forwarded, prompt1) {
		t.Errorf("first provider request does not carry the first prompt %q: %q", prompt1, forwarded)
	}
	body, _ = requests[len(requests)-1]["body"].(map[string]any)
	if forwarded := lastUserText(body); !strings.Contains(forwarded, prompt2) {
		t.Errorf("last provider request does not carry the post-restart prompt: %q", forwarded)
	}

	// The transcript survived the restart in the same session.
	reply := strings.Join(eventText(streamSnapshot(t, id), "message"), "\n")
	if !strings.Contains(reply, "echo: "+prompt1) || !strings.Contains(reply, "echo: "+prompt2) {
		t.Fatalf("transcript after the restart is missing a turn; got:\n%s", reply)
	}
}
