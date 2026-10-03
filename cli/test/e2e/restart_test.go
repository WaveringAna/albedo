//go:build unix

// A read through a ChatClient built before a real daemon restart refreshes
// its connection before another turn without losing the first turn's transcript.
// A fake daemon cannot exercise process lifetime or on-disk session persistence.
package e2e

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui"

	tea "charm.land/bubbletea/v2"
)

// restartDaemon replaces the suite daemon under the same hermetic home and
// records its new pid for later scenarios.
func restartDaemon(t *testing.T) daemon.ConnectionSnapshot {
	t.Helper()
	old := suite.daemonPID

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := daemon.StopDaemon(ctx, conn(t)); err != nil {
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

// TestChatClientReadReconnectsAfterDaemonRestart recovers a read before
// sending another turn through the same client and persisted session.
func TestChatClientReadReconnectsAfterDaemonRestart(t *testing.T) {
	profile := providerRoute(t, echoReply)
	workspace := t.TempDir()
	id := newSession(t, workspace)
	configured := daemonSession(t, id)
	if _, err := daemon.SelectModel(t.Context(), conn(t), id, daemon.ModelSelectionRequest{Model: "o3", Effort: "high", ETag: configured.ETag}); err != nil {
		t.Fatalf("select a model with a default effort: %v", err)
	}
	configured = daemonSession(t, id)
	if configured.Effort != "high" {
		t.Fatalf("selected effort is %q, want high", configured.Effort)
	}
	if _, err := daemon.SelectEffort(t.Context(), conn(t), configured, ""); err != nil {
		t.Fatalf("clear the effort preference: %v", err)
	}
	if cleared := daemonSession(t, id); cleared.Effort != "" {
		t.Fatalf("cleared effort is %q", cleared.Effort)
	}

	// Reads and turns use the same client across the restart so they exercise
	// connection recovery rather than a new attachment.
	shared := conn(t)
	client := daemon.NewChatClient(shared, id)

	prompt1 := "turn before the restart"
	if _, err := client.Send(context.Background(), prompt1, nil); err != nil {
		t.Fatalf("first send: %v", err)
	}
	waitIdle(t, id, profile, 1)

	oldSnap := shared.Snapshot()
	snap := restartDaemon(t)
	if reopened := daemonSession(t, id); reopened.Effort != "" {
		t.Fatalf("restart replaced the cleared effort with %q", reopened.Effort)
	}

	page, err := client.History(context.Background(), 0, 120)
	if err != nil || len(page.Events) == 0 {
		t.Fatalf("read recovery after restart: %+v, %v", page, err)
	}

	prompt2 := "turn after the restart"
	sent, err := client.Send(context.Background(), prompt2, nil)
	if err != nil || sent == nil || !sent.OK {
		t.Fatalf("second send through the same client after the restart: ok=%v err=%v", sent != nil && sent.OK, err)
	}
	waitIdle(t, id, profile, 2)
	if continued := daemonSession(t, id); continued.Effort != "" {
		t.Fatalf("resumed turn replaced the cleared effort with %q", continued.Effort)
	}

	// The shared connection must now describe the restarted daemon, not the
	// one it was built on.
	current := shared.Snapshot()
	if current.Pid != snap.Pid {
		t.Errorf("connection pid is %d, restarted daemon is %d", current.Pid, snap.Pid)
	}
	if current.Token != snap.Token {
		t.Errorf("connection token is not the restarted daemon's")
	}
	if want := fmt.Sprintf("http://127.0.0.1:%d", snap.Port); shared.BaseURL() != want {
		t.Errorf("connection base url is %s, want %s", shared.BaseURL(), want)
	}
	if current.Token == oldSnap.Token {
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
	reply := strings.Join(eventText(durableHistorySnapshot(t, id), "message"), "\n")
	if !strings.Contains(reply, "echo: "+prompt1) || !strings.Contains(reply, "echo: "+prompt2) {
		t.Fatalf("transcript after the restart is missing a turn; got:\n%s", reply)
	}
}

// A stopped turn survives a daemon restart as idle-but-interrupted. Reopening
// it must accept ordinary input without a slash command changing its phase.
func TestTUIReopensInterruptedSessionWithoutCompacting(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	defer close(release)
	profile := providerRoute(t, func(request map[string]any) string {
		if lastUserText(request) == "stop this turn" {
			close(entered)
			<-release
		}
		return echoReply(request)
	})
	id := newSession(t, t.TempDir())
	client := daemon.NewChatClient(conn(t), id)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := client.Send(ctx, "stop this turn", nil); err != nil {
		t.Fatal(err)
	}
	select {
	case <-entered:
	case <-ctx.Done():
		t.Fatal("the turn never reached the provider")
	}
	if interrupted, err := daemon.InterruptSession(ctx, conn(t), id); err != nil || !interrupted {
		t.Fatalf("interrupt: %v, %v", interrupted, err)
	}
	waitIdle(t, id, profile, 1)
	restartDaemon(t)
	status, err := daemon.NewChatClient(conn(t), id).GetStatus(ctx)
	if err != nil || !status.Idle || status.Phase == nil || *status.Phase != daemon.PhaseIdle {
		t.Fatalf("reopened status: %+v, %v", status, err)
	}

	session := daemonSession(t, id)
	d := driveTUI(t, &session)
	defer d.App.Chat.Close()
	page, err := client.History(ctx, 0, 120)
	if err != nil {
		t.Fatal(err)
	}
	for _, event := range page.Events {
		d.Update(tui.ChatStreamEventMsg{
			SessionID: id, Generation: d.App.Chat.Generation, Event: event,
		})
	}
	if !strings.Contains(d.View(), "stop this turn") {
		t.Fatal("the interrupted transcript did not load")
	}
	d.connected()
	d.App.Chat.TextArea.SetValue("continue without compacting")
	command := d.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if command == nil {
		t.Fatal("the composer refused the new prompt")
	}
	for _, msg := range d.results(command) {
		if _, ok := msg.(tui.ChatTurnSentMsg); ok {
			d.Update(msg)
		}
	}
	waitIdle(t, id, profile, 2)
	replies := strings.Join(eventText(durableHistorySnapshot(t, id), "message"), "\n")
	if !strings.Contains(replies, "echo: continue without compacting") {
		t.Fatalf("the reopened session did not answer: %q", replies)
	}
}
