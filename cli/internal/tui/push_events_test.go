package tui

import (
	"net/http"
	"testing"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/daemon/protocol"
)

// A pushed kernel event carries the job facts a status read used to bring, and
// a pushed glances event replaces the sidebar. Neither disturbs the turn's own
// phase, which the status events own.
func TestPushedKernelAndGlanceEventsUpdateTheFooter(t *testing.T) {
	conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("a pushed event made a request: %s", r.URL)
	})
	session := &daemon.Session{ID: "original"}
	chat := NewChatModel(session, daemon.NewChatClient(conn, session.ID))
	t.Cleanup(chat.Close)
	chat.SetSize(100, 40)
	phase := daemon.PhaseModel
	chat.Status = daemon.AgentStatus{Phase: &phase, Running: true, Idle: false}
	jobs := int64(2)
	chat.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventKernel, Kernel: &protocol.Kernel{
		State:        "attached",
		Stage:        new("ssh"),
		Build:        new("build-b"),
		InstanceID:   new("kernel-b"),
		LiveJobCount: &jobs,
		RunningJobs: []protocol.KernelJob{
			{ID: "job1", Command: "sleep 10"},
		},
	}})
	status := chat.Status
	if status.KernelLink != "attached" || status.KernelStep != "ssh" || status.KernelJobs == nil || *status.KernelJobs != 2 || len(status.RunningJobs) != 1 || status.KernelBuild == nil || *status.KernelBuild != "build-b" || status.KernelInstanceID == nil || *status.KernelInstanceID != "kernel-b" {
		t.Fatalf("pushed kernel facts lost: %+v", status)
	}
	if status.Phase == nil || *status.Phase != phase || !status.Running {
		t.Fatalf("a kernel event changed the turn's phase: %+v", status)
	}

	chat.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventGlances, Glances: []daemon.PageGlance{{Title: "Second"}, {Title: "First"}}})
	if len(chat.Glances) != 2 || chat.Glances[0].Title != "Second" || chat.Glances[1].Title != "First" {
		t.Fatalf("pushed glances not applied: %+v", chat.Glances)
	}
	// An empty sidebar is an observed value, not a reason to keep the old one.
	chat.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventGlances, Glances: nil})
	if len(chat.Glances) != 0 {
		t.Fatalf("an emptied sidebar kept its rows: %+v", chat.Glances)
	}
}
