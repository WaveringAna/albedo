package tui

import (
	"albedo/cli/internal/daemon"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func TestSessionViewerSearchAndRefresh(t *testing.T) {
	m := NewSessionViewer("/work/current")
	m.SetSize(70, 20)
	sessions := []daemon.Session{
		{ID: "first", Title: "Fix tests", Workspace: "/work/alpha", Model: "sonnet"},
		{ID: "second", Title: "Ship UI", Workspace: "/work/beta", Model: "opus"},
	}
	m.SetSessions(sessions, nil)
	if item, _ := m.Highlighted(); item.ID != "first" {
		t.Fatalf("initial selection: %q", item.ID)
	}
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyDown})
	if item, _ := m.Highlighted(); item.ID != "second" {
		t.Fatalf("navigation: %q", item.ID)
	}
	m.SetSessions(sessions, nil)
	if item, _ := m.Highlighted(); item.ID != "second" {
		t.Fatalf("refresh lost selection: %q", item.ID)
	}
	m.SearchInput.SetValue("beta opus")
	m.applyFilter()
	if len(m.Filtered) != 1 || m.Filtered[0].ID != "second" {
		t.Fatalf("filtered: %+v", m.Filtered)
	}
	m.SetSessions(sessions, nil)
	if m.SearchInput.Value() != "beta opus" || len(m.Filtered) != 1 {
		t.Fatal("refresh lost search")
	}
	if !strings.Contains(ansi.Strip(m.View()), "Ship UI") {
		t.Fatal("session title missing")
	}
}

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

func TestSessionViewerActiveAndUntrustedTitle(t *testing.T) {
	m := NewSessionViewer("/work/current")
	m.SetSize(60, 16)
	active := daemon.Session{ID: "active", Title: "\x1b[31mHello\nworld", Workspace: "/work/current"}
	m.SetSessions(nil, &active)
	if item, _ := m.Highlighted(); item.ID != active.ID {
		t.Fatalf("active selection: %q", item.ID)
	}
	view := m.View()
	if strings.Contains(view, "\x1b[31m") || !strings.Contains(ansi.Strip(view), "Hello world") {
		t.Fatalf("unsafe or missing title: %q", view)
	}
}

func viewerAt(now time.Time) SessionViewer {
	m := NewSessionViewer("/work/current")
	m.now = func() time.Time { return now }
	return m
}

func TestSessionViewerFavouritesColumnAndPins(t *testing.T) {
	now := time.Date(2026, 9, 23, 12, 0, 0, 0, time.Local)
	at := func(d time.Duration) *int64 { v := now.Add(-d).Unix(); return &v }
	sessions := []daemon.Session{
		{ID: "old", Title: "Old", LastAssistantAt: at(30 * 24 * time.Hour)},
		{ID: "today", Title: "Today", LastAssistantAt: at(time.Hour)},
		{ID: "busy", Title: "Busy", LastAssistantAt: at(3 * 24 * time.Hour)},
		{ID: "pin", Title: "Pinned", LastAssistantAt: at(40 * 24 * time.Hour)},
	}
	path := filepath.Join(t.TempDir(), "picker.json")
	if err := (sessionPrefs{Pinned: []string{"pin", "gone"}, Opens: map[string]int{"busy": 3, "old": 1}}).save(path); err != nil {
		t.Fatal(err)
	}
	m := viewerAt(now)
	m.LoadPrefs(path)
	m.SetSize(170, 30)
	m.SetSessions(sessions, nil)

	var order []string
	for _, item := range m.Filtered {
		order = append(order, item.ID)
	}
	if got := strings.Join(order, " "); got != "new login pin busy today old" {
		t.Fatalf("order: %s", got)
	}
	if item, _ := m.Highlighted(); item.ID != "today" {
		t.Fatalf("initial highlight: %s", item.ID)
	}
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyTab})
	if item, _ := m.Highlighted(); item.ID != "pin" {
		t.Fatalf("tab to favourites: %s", item.ID)
	}
	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyRight})
	if item, _ := m.Highlighted(); item.ID != "today" {
		t.Fatalf("right to recent: %s", item.ID)
	}

	m, _ = m.Update(tea.KeyMsg{Type: tea.KeyCtrlS})
	if m.section["today"] != secPinned {
		t.Fatal("ctrl+s did not pin")
	}
	if item, _ := m.Highlighted(); item.ID != "today" {
		t.Fatalf("pin moved the cursor to %s", item.ID)
	}
	m.Prune(sessions)
	saved := loadSessionPrefs(path)
	if strings.Join(saved.Pinned, " ") != "pin today" {
		t.Fatalf("saved pins: %v", saved.Pinned)
	}
	if !strings.Contains(ansi.Strip(m.View()), "pinned 2") {
		t.Fatal("pinned heading missing")
	}

	// Opens promote a session once it passes the threshold.
	m.RecordOpen("old")
	m.SetSessions(sessions, nil)
	if m.section["old"] != secFrequent {
		t.Fatalf("old section %d after two opens", m.section["old"])
	}
}

func TestSessionViewerPreviewFetchesOnSettleAndRenders(t *testing.T) {
	now := time.Date(2026, 9, 23, 12, 0, 0, 0, time.Local)
	stamp := now.Add(-time.Minute).Unix()
	sessions := []daemon.Session{
		{ID: "one", Title: "First", Model: "sonnet", LastAssistantAt: &stamp},
		{ID: "two", Title: "Second", Model: "opus", LastAssistantAt: &stamp},
	}
	var fetched []string
	m := viewerAt(now)
	m.Fetch = func(id string) tea.Cmd {
		fetched = append(fetched, id)
		return nil
	}
	m.SetSize(120, 30)
	m.SetSessions(sessions, nil)

	m, cmd := m.Update(tea.KeyMsg{Type: tea.KeyDown})
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
	m, _ = m.Update(SessionPreviewMsg{ID: "two", Preview: SessionPreview{Total: 9, Items: []PreviewItem{
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
	if !strings.Contains(ansi.Strip(m.View()), "newer daemon") {
		t.Fatal("missing daemon hint")
	}
}

func TestSessionViewerUndatedSessionsFollowActivity(t *testing.T) {
	now := time.Date(2026, 9, 23, 12, 0, 0, 0, time.Local)
	at := func(d time.Duration) *int64 { v := now.Add(-d).Unix(); return &v }
	sessions := []daemon.Session{
		{ID: "waiting", Title: "prompt sent, no reply yet"},
		{ID: "today", Title: "Today", LastAssistantAt: at(time.Hour)},
		{ID: "old", Title: "Old", LastAssistantAt: at(30 * 24 * time.Hour)},
		{ID: "fresh", Title: ""},
	}
	m := viewerAt(now)
	m.SetSessions(sessions, &sessions[3])
	var order []string
	for _, item := range m.Filtered {
		order = append(order, item.ID)
	}
	if got := strings.Join(order, " "); got != "new login fresh waiting today old" {
		t.Fatalf("order: %s", got)
	}
	if m.section["fresh"] != secToday || m.section["waiting"] != secToday {
		t.Fatalf("sections: %v", m.section)
	}
	m.SetSessions(sessions, nil)
	if m.section["fresh"] != secEarlier {
		t.Fatalf("empty inactive session: %d", m.section["fresh"])
	}
}
