// The chat header drops whole parts as the terminal narrows instead of
// cutting one short, and a remote workspace's host is never one of them.
// The layout depends only on the width, so the rule is checked across every
// width here; an e2e would see one terminal size.
package tui

import (
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/daemon/protocol"
	"github.com/charmbracelet/x/ansi"
)

func TestHeaderKeepsTheWorkspaceNameAndModelWhole(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.AgentName, m.Workspace, m.Model, m.Effort = "albedo", "/src/proj/tangled", "claude-opus-4-6", "high"
	m.Glances = []PageGlance{
		{Title: "pending work", Rows: []PageRow{{ID: "1", Text: "x"}}},
		{Title: "open vents", Rows: []PageRow{{ID: "2", Text: "y"}}},
	}
	const model = "claude-opus-4-6:high"
	for width := 1; width <= 120; width++ {
		header := ansi.Strip(m.header(width))
		if got := ansi.StringWidth(header); got > width {
			t.Fatalf("width %d: header %q is %d wide", width, header, got)
		}
		if width >= len(model) && !strings.Contains(header, model) {
			t.Fatalf("width %d: header %q cut the model", width, header)
		}
		if width >= len("tangled")+len(model)+3 && !strings.Contains(header, "tangled") {
			t.Fatalf("width %d: header %q cut the workspace name", width, header)
		}
	}
	if header := ansi.Strip(m.header(100)); !strings.Contains(header, "pending work 1  open vents 1") {
		t.Fatalf("a wide header without a sidebar should count every glance: %q", header)
	}
}

func TestRemoteHeaderKeepsTheHostWholeAndFoldsOnlyThePath(t *testing.T) {
	label := "chernobog"
	m := newTestChatModel(t, &daemon.Session{
		ID:        "s",
		Workspace: "mayer@chernobog:/home/mayer/proj/albedo",
		Location:  &daemon.Location{Label: &label},
	})
	m.AgentName, m.Model = "albedo", "claude-opus-4-6"
	const model = "claude-opus-4-6"
	if header := ansi.Strip(m.header(120)); !strings.Contains(header, "✦ albedo on chernobog:/home/mayer/proj/albedo") {
		t.Fatalf("a wide header should name the host and the whole path: %q", header)
	}
	for width := 1; width <= 120; width++ {
		header := ansi.Strip(m.header(width))
		if got := ansi.StringWidth(header); got > width {
			t.Fatalf("width %d: header %q is %d wide", width, header, got)
		}
		if strings.Contains(header, "mayer@") {
			t.Fatalf("width %d: header %q shows the user the label left out", width, header)
		}
		if strings.Contains(header, "/") && !strings.Contains(header, "chernobog:") {
			t.Fatalf("width %d: header %q shows the path without its host", width, header)
		}
		if width >= len("chernobog:albedo")+len(model)+3 && !strings.Contains(header, "chernobog:") {
			t.Fatalf("width %d: header %q dropped the host", width, header)
		}
	}
}

func TestRemoteHeaderFoldsUnderTheHostsHomeAndSaysWhileConnecting(t *testing.T) {
	label := "chernobog"
	m := newTestChatModel(t, &daemon.Session{
		ID:        "s",
		Workspace: "mayer@chernobog:/home/mayer/proj/albedo",
		Location:  &daemon.Location{Label: &label},
	})
	m.AgentName, m.Model = "albedo", "claude-opus-4-6"
	m.Status = daemon.AgentStatus{Idle: true, KernelLink: "booting"}
	if got := m.statusLine(); got != "connecting to chernobog…" {
		t.Fatalf("a booting remote kernel reads %q", got)
	}
	m.Status.KernelStep = "staging"
	if got := m.statusLine(); got != "copying the kernel to chernobog…" {
		t.Fatalf("a first boot on the host reads %q", got)
	}
	m.Status.KernelStep = ""
	// an idle session animates too, with the face the picker shows for the host
	m.ProgressFrame = 1
	if view := ansi.Strip(m.View()); !m.animating() || !strings.Contains(view, "connecting to chernobog… "+connectingFace("chernobog", 1)) {
		t.Fatalf("connecting should animate (animating %v):\n%s", m.animating(), view)
	}
	m.Status.KernelLink, m.hostHome = "attached", "/home/mayer"
	if header := ansi.Strip(m.header(120)); !strings.Contains(header, "✦ albedo on chernobog:proj/albedo") {
		t.Fatalf("the path should fold under the host's own home: %q", header)
	}
	if got := m.statusLine(); strings.Contains(got, "connecting") {
		t.Fatalf("an attached kernel still reads %q", got)
	}
	m.Status.KernelLink = "lost"
	if got := m.statusLine(); got != "kernel on chernobog lost · the next turn starts a fresh one" {
		t.Fatalf("a lost kernel reads %q", got)
	}
}

func TestBackgroundJobsRenderInHeaderStatusAndSidebar(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.AgentName, m.Workspace, m.Model = "albedo", "/src/proj/albedo", "claude-opus-4-6"
	m.Status = daemon.AgentStatus{
		Idle:       true,
		KernelJobs: new(int64(1)),
		RunningJobs: []protocol.KernelJob{
			{ID: "job1", Command: "go test ./..."},
		},
	}

	if got := m.statusLine(); got != "1 background job running · go test ./..." {
		t.Fatalf("expected statusLine to show 1 running job, got %q", got)
	}
	if !m.animating() {
		t.Fatalf("expected model to animate when background jobs are running")
	}

	header := ansi.Strip(m.header(120))
	if !strings.Contains(header, "background jobs 1") {
		t.Fatalf("expected header to count running jobs glance, got %q", header)
	}

	m.Glances = []PageGlance{{Title: "open vents", Rows: []PageRow{{ID: "v1", Text: "a vent"}}}}
	m.SetSize(140, 30)
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "background jobs") || !strings.Contains(view, "go test ./...") {
		t.Fatalf("expected sidebar to show running background job, got:\n%s", view)
	}

	if len(m.Glances) != 1 || m.Glances[0].Title != "open vents" {
		t.Fatal("rendering jobs changed extension glances")
	}
	for width := 1; width <= 140; width++ {
		m.SetSize(width, 30)
		if got := ansi.StringWidth(m.header(width)); got > width {
			t.Fatalf("job header at width %d exceeds its bounds: %d", width, got)
		}
	}
	m.Glances = nil
	m.Status.KernelJobs = nil
	m.Status.RunningJobs = nil
	if m.animating() || m.statusLine() != "" || len(m.activeGlances()) != 0 {
		t.Fatal("unknown jobs must not claim that background work is running")
	}

	m.Status.KernelJobs = new(int64(2))
	m.Status.RunningJobs = []protocol.KernelJob{
		{ID: "job1", Command: "sleep 10"},
		{ID: "job2", Command: "cargo build"},
	}
	if got := m.statusLine(); got != "2 background jobs running · sleep 10" {
		t.Fatalf("expected statusLine to show 2 running jobs, got %q", got)
	}

	m.Status.KernelJobs = new(int64(0))
	m.Status.RunningJobs = nil
	if got := m.statusLine(); got != "" {
		t.Fatalf("expected empty statusLine when idle with no jobs, got %q", got)
	}
}

func TestBackgroundJobsRefreshWithoutStartingATurn(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 30)
	status := daemon.AgentStatus{Idle: true, KernelJobs: new(int64(1)),
		RunningJobs: []protocol.KernelJob{{ID: "j", Command: "sleep 10"}}}
	m, cmd := m.Update(ChatStatusMsg{SessionID: m.SessionID, Generation: m.Generation,
		Revision: m.statusRevision, Status: &status})
	if !m.animating() || cmd == nil || !strings.Contains(m.statusLine(), "sleep 10") {
		t.Fatal("idle background job did not start its status animation")
	}
	status.KernelJobs, status.RunningJobs = new(int64(0)), nil
	m, _ = m.Update(ChatStatusMsg{SessionID: m.SessionID, Generation: m.Generation,
		Revision: m.statusRevision, Status: &status})
	if m.animating() || m.statusLine() != "" || len(m.activeGlances()) != 0 {
		t.Fatal("finished jobs left idle job chrome behind")
	}
}

func TestYoungJobsStayOutOfTheBackgroundChrome(t *testing.T) {
	// The threshold is render logic over a started_at the daemon reports; an
	// e2e would have to wait out the grace to see either side of it.
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(140, 30)
	m.Status = daemon.AgentStatus{
		Idle:       true,
		KernelJobs: new(int64(1)),
		RunningJobs: []protocol.KernelJob{
			{ID: "job1", Command: "rg pattern", StartedAt: time.Now().UnixMilli()},
		},
	}

	if m.animating() || m.statusLine() != "" || len(m.activeGlances()) != 0 {
		t.Fatal("a job inside its grace is not background work yet")
	}
	if got := m.runningJobCommand(); got != "rg pattern" {
		t.Fatalf("the action row still names the job a running cell is on: %q", got)
	}

	// one aged job shows, one live remote job the list cannot name still counts
	m.Status.KernelJobs = new(int64(3))
	m.Status.RunningJobs = append(m.Status.RunningJobs,
		protocol.KernelJob{ID: "job2", Command: "cargo build", StartedAt: time.Now().Add(-10 * time.Second).UnixMilli()})
	if got := m.statusLine(); got != "2 background jobs running · cargo build" {
		t.Fatalf("aged jobs count and lead the idle status line, got %q", got)
	}
	view := ansi.Strip(m.View())
	if strings.Contains(view, "rg pattern") || !strings.Contains(view, "cargo build") {
		t.Fatalf("the sidebar hides the young job and shows the aged one:\n%s", view)
	}
}
