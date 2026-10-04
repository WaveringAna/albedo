// Two invariants the e2e suite cannot reach, because each lives inside the
// tui package or only shows up mid-flight:
//
//   - layout: at every terminal size the viewer must fit its rows and columns
//     and keep the highlighted session visible — no daemon run observes a
//     given width/height pair;
//   - preview timing: a debounce, a stale tick for a row no longer
//     highlighted, and the cache stamp that decides when a new reply
//     invalidates a preview are race-dependent state a scripted scenario
//     reaches only flakily;
//   - grouping: within a group, sessions the daemon still holds lead the
//     reaped ones.
package tui

import (
	"albedo/cli/internal/daemon"
	"errors"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestSessionViewerResponsiveViewport(t *testing.T) {
	for _, size := range [][2]int{{170, 34}, {110, 28}, {80, 24}, {46, 10}, {25, 7}, {12, 5}} {
		m := NewSessionViewer("/work/current")
		m.SetSize(size[0], size[1])
		sessions := []daemon.Session{
			{ID: "one", Title: "A very long session title that cannot fit on a single line", Workspace: "/work/alpha"},
			{ID: "two", Title: "Selected session", Workspace: "/work/beta"},
		}
		m.SetSessions(sessions, nil)
		m.Cursor = len(m.Filtered) - 1
		view := m.View()
		lines := strings.Split(view, "\n")
		if len(lines) > size[1] {
			t.Errorf("%dx%d: %d lines", size[0], size[1], len(lines))
		}
		for _, line := range lines {
			if ansi.StringWidth(line) > size[0] {
				t.Errorf("%dx%d: line too wide: %q", size[0], size[1], line)
			}
		}
		if !strings.Contains(ansi.Strip(view), "Selected session") && size[0] >= 25 {
			t.Errorf("%dx%d: selected row not visible", size[0], size[1])
		}
	}
}

func TestSessionViewerPutsWarmSessionsFirst(t *testing.T) {
	now := time.Date(2026, 9, 23, 12, 0, 0, 0, time.Local)
	newest, recent, stale := now.Add(-time.Minute).Unix(), now.Add(-10*time.Minute).Unix(), now.Add(-2*time.Hour).Unix()
	m := viewerAt(now)
	m.SetSize(120, 30)
	// the daemon lists by activity; a loaded session whose last turn is over
	// an hour old has a cold cache and keeps the daemon's order
	m.SetSessions([]daemon.Session{
		{ID: "reaped", Title: "Reaped session", LastAssistantAt: &newest},
		{ID: "warm", Title: "Warm session", LastAssistantAt: &recent, Cursor: &daemon.Cursor{}},
		{ID: "cold", Title: "Cold session", LastAssistantAt: &stale, Cursor: &daemon.Cursor{}},
	}, nil)
	view := ansi.Strip(m.View())
	warmAt, reapedAt, coldAt := strings.Index(view, "Warm session"), strings.Index(view, "Reaped session"), strings.Index(view, "Cold session")
	if warmAt < 0 || reapedAt < warmAt || coldAt < reapedAt {
		t.Fatalf("a warm session must lead, and a cold loaded one must not:\n%s", view)
	}
}

func viewerAt(now time.Time) SessionViewer {
	m := NewSessionViewer("/work/current")
	m.now = func() time.Time { return now }
	return m
}

func TestSessionViewerPreviewFetchesOnSettleAndRenders(t *testing.T) {
	now := time.Date(2026, 9, 23, 12, 0, 0, 0, time.Local)
	stamp := now.Add(-time.Minute).Unix()
	sessions := []daemon.Session{
		{ID: "one", Title: "First", Model: "sonnet", LastAssistantAt: &stamp},
		{ID: "two", Title: "Second", Model: "opus", LastAssistantAt: &stamp, TranscriptCount: 9},
	}
	var fetched []string
	m := viewerAt(now)
	m.Fetch = func(id string) tea.Cmd {
		fetched = append(fetched, id)
		return nil
	}
	m.SetSize(120, 30)
	m.SetSessions(sessions, nil)

	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
	if cmd == nil {
		t.Fatal("moving did not schedule a preview")
	}
	// A stale tick for a row no longer highlighted is ignored.
	m, _ = m.Update(sessionPreviewTickMsg{ID: "one"})
	m, _ = m.Update(sessionPreviewTickMsg{ID: "two"})
	m, _ = m.Update(sessionPreviewTickMsg{ID: "two"})
	if strings.Join(fetched, " ") != "two" {
		t.Fatalf("fetched: %v", fetched)
	}
	m, _ = m.Update(SessionPreviewMsg{ID: "two", Preview: daemon.SessionPreview{Items: []daemon.PreviewItem{
		{Type: "user", Preview: "please fix the flaky test"},
		{Type: "tool", Preview: "read"}, {Type: "tool", Preview: "read"}, {Type: "tool", Preview: "bash"},
		{Type: "assistant", Preview: "fixed the race in the watcher"},
	}}})
	view := ansi.Strip(m.View())
	for _, want := range []string{"please fix the flaky test", "read ×2, bash", "fixed the race", "9 messages", "opus"} {
		if !strings.Contains(view, want) {
			t.Errorf("preview missing %q:\n%s", want, view)
		}
	}

	// A newer reply invalidates the cached preview; a failure shows a hint.
	newer := stamp + 60
	sessions[1].LastAssistantAt = &newer
	m.SetSessions(sessions, nil)
	if m.PreviewCmd() == nil {
		t.Fatal("new reply did not refresh the preview")
	}
	m.fetchPreview("two")
	m, _ = m.Update(SessionPreviewMsg{ID: "two", Err: errors.New("unknown operation")})
	if preview := m.previews["two"]; preview == nil || preview.loading || !preview.err {
		t.Fatal("failed preview did not leave loading state")
	}
}

func TestSessionViewerArchiveKeepsCursorSlot(t *testing.T) {
	m := NewSessionViewer("/work/current")
	m.SetSize(120, 30)
	m.SetSessions([]daemon.Session{{ID: "a"}, {ID: "b"}, {ID: "c"}, {ID: "d"}}, nil)
	m.focus("b")
	slot := m.Cursor
	m.prefs.Archived = []string{"b"}
	m.rebuild()
	if item, _ := m.Highlighted(); item.ID != "c" || m.Cursor != slot {
		t.Fatalf("cursor %d on %q, want slot %d on c", m.Cursor, item.ID, slot)
	}
	m.focus("d")
	m.prefs.Archived = []string{"b", "d"}
	m.rebuild()
	if item, _ := m.Highlighted(); item.ID != "c" {
		t.Fatalf("archiving the last session left the cursor on %q, want c", item.ID)
	}
}
