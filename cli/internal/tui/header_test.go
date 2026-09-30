// The chat header drops whole parts as the terminal narrows instead of
// cutting one short. The layout depends only on the width, so the rule is
// checked across every width here; an e2e would see one terminal size.
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
