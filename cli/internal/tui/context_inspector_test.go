// The context inspector shows the prepared request's standing and each
// section's facts without enter, filters sections by typing, and scrolls a
// section's content in its own reader. The reader's body height is only known
// to the frame, so these drive View first and then assert the scroll it allows.
package tui

import (
	"albedo/cli/internal/daemon"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func contextFixture(t *testing.T) ContextInspectorModel {
	t.Helper()
	m := NewContextInspectorModel(nil, "s")
	m.SetSize(120, 30)
	m, _ = m.Update(contextSnapshotLoadedMsg{Gen: m.Generation, Snapshot: &daemon.ContextSnapshot{
		State: "ready", Provider: "claude", Model: "claude-x", Protocol: "messages",
		Sections: []daemon.ContextSection{
			{ID: "history", Label: "History", Kind: "history", Source: "transcript", Pages: 2, ByteCount: 4096, Preview: "user: hello"},
			{ID: "system", Label: "System", Kind: "system", Source: "instructions"},
		},
	}})
	if m.Snapshot == nil || len(m.shown) != 2 {
		t.Fatal("fixture snapshot did not load")
	}
	return m
}

func TestContextShowsRequestAndSectionFactsWithoutEnter(t *testing.T) {
	m := contextFixture(t)
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "claude · claude-x · messages") || !strings.Contains(view, "read-only") {
		t.Fatalf("the prepared request should show above the sections:\n%s", view)
	}
	if !strings.Contains(view, "2 pages") || !strings.Contains(view, "transcript") {
		t.Fatalf("the highlighted section's facts should show without opening it:\n%s", view)
	}
}

func TestContextFilterSectionsByTyping(t *testing.T) {
	m := contextFixture(t)
	for _, r := range "sys" {
		m, _ = m.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	view := ansi.Strip(m.View())
	if strings.Contains(view, "History") || !strings.Contains(view, "System") {
		t.Fatalf("typing should filter the sections:\n%s", view)
	}
	if row, _ := m.highlighted(); row.key != "system" {
		t.Fatalf("the filter left %q under the cursor", row.key)
	}
}

func TestContextReaderScrollsAndReturnsOnEsc(t *testing.T) {
	m := contextFixture(t)
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.Detail == nil {
		t.Fatal("enter should open the section reader")
	}
	content := strings.Repeat("history line\n", 80)
	m, _ = m.Update(contextPageLoadedMsg{Gen: m.Generation, SectionID: "history", Data: &daemon.ContextPage{Content: content}})
	m.View()
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
	if m.Detail.Scroll != 3 {
		t.Fatalf("down should scroll one line each press, got %d", m.Detail.Scroll)
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyPgDown})
	if m.Detail.Scroll <= 3 || m.Detail.Scroll > len(m.Detail.wrapped) {
		t.Fatalf("pgdown should jump by a body of rows, stayed inside the content: %d", m.Detail.Scroll)
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if m.Detail != nil || !strings.Contains(ansi.Strip(m.View()), "claude-x") {
		t.Fatal("esc should return to the sections")
	}
}
