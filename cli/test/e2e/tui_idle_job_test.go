//go:build unix

package e2e

// An idle session whose kernel still runs a job is not a wait: the client
// keeps the status line's marker and draws no face, so a job that outlives its
// turn costs the terminal nothing per second. The face itself is only ever
// seen by a person watching the terminal, so the view is where it shows.

import (
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui"
)

func TestTUIIdleBackgroundJobKeepsItsMarkerWithoutAFace(t *testing.T) {
	profile := providerRoute(t, func(request map[string]any) string {
		if toolAnswered(request) {
			return "the job keeps running on its own"
		}
		return pythonCall("job = run(\"sleep\", \"300\")\nprint(job)")
	})
	t.Parallel()
	session := newSession(t, t.TempDir())
	client := daemon.NewChatClient(conn(t), session)
	if _, err := client.Send(t.Context(), "leave a job running", nil); err != nil {
		t.Fatal(err)
	}
	waitIdle(t, session, profile, 2)

	// The interface calls a job background work only once it outlives its
	// grace; until then it is the cell the turn is still on.
	deadline := time.Now().Add(30 * time.Second)
	for {
		status, err := client.GetStatus(t.Context())
		if err != nil {
			t.Fatalf("status of %s: %v", session, err)
		}
		if len(status.RunningJobs) > 0 && time.Since(time.UnixMilli(status.RunningJobs[0].StartedAt)) > 4*time.Second {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("no background job outlived its grace: %+v", status)
		}
		time.Sleep(200 * time.Millisecond)
	}

	current := daemonSession(t, session)
	driver := driveTUI(t, &current)
	t.Cleanup(func() { driver.App.Chat.Close() })
	chat := driver.App.Chat
	reply := driver.Update(tui.ChatStatusPollMsg{SessionID: chat.SessionID, Generation: chat.Generation})()
	status, ok := reply.(tui.ChatStatusMsg)
	if !ok || status.Err != nil || status.Status == nil {
		t.Fatalf("status read produced %#v: %v", reply, status.Err)
	}
	driver.Update(status)
	view := driver.View()
	marker := ""
	for _, line := range strings.Split(view, "\n") {
		if strings.Contains(line, "background job running") {
			marker = strings.TrimSpace(line)
		}
	}
	if !strings.HasPrefix(marker, "1 background job running · sleep 300") {
		t.Fatalf("the idle job marker reads %q:\n%s", marker, view)
	}
	// every face is parenthesised; the marker is not
	if strings.Contains(marker, "(") {
		t.Fatalf("an idle background job animated a face: %q", marker)
	}
	if !strings.Contains(view, "ctrl+g editor") {
		t.Fatalf("an idle session with background work is a session you can type into:\n%s", view)
	}
}
