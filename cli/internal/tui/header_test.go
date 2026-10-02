// The chat header drops whole parts as the terminal narrows instead of
// cutting one short, and a remote workspace's host is never one of them.
// The layout depends only on the width, so the rule is checked across every
// width here; an e2e would see one terminal size.
package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
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
	if header := ansi.Strip(m.header(120)); !strings.Contains(header, "✦ albedo on chernobog:~/proj/albedo") {
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
