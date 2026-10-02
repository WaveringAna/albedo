// The folder picker's query grammar and host states are bug-prone logic
// the e2e suite cannot reach without a real remote host: which text lists a
// host's folders, which completes a host, how remote paths fold under that
// host's home, and that a dead host is never picked.
package tui

import (
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"

	"albedo/cli/internal/daemon"
)

func TestParseQuery(t *testing.T) {
	for _, c := range []struct {
		q, dir, segment string
		kind            queryKind
	}{
		{"", "", "", queryRecent},
		{"albedo", "", "albedo", queryRecent},
		{"~", "~", "", queryListing},
		{"~/pro", "~/", "pro", queryListing},
		{"/srv/", "/srv/", "", queryListing},
		{"src/", "src/", "", queryListing},
		{"mayer@cher", "", "mayer@cher", queryHosts},
		{"@cher", "", "@cher", queryHosts},
		{"chernobog:", "chernobog:~", "", queryListing},
		{"chernobog:~", "chernobog:~", "", queryListing},
		{"chernobog:pro", "chernobog:~", "pro", queryListing},
		{"chernobog:~/proj/", "chernobog:~/proj/", "", queryListing},
		{"chernobog:~/proj/al", "chernobog:~/proj/", "al", queryListing},
		{"mayer@chernobog:/srv/", "mayer@chernobog:/srv/", "", queryListing},
		{"[::1]:/tmp/x", "[::1]:/tmp/", "x", queryListing},
		// a slash before the colon is a local path, as the daemon reads it
		{"a/b:c/", "a/b:c/", "", queryListing},
	} {
		got := parseQuery(c.q)
		if got.kind != c.kind || got.dir != c.dir || got.segment != c.segment {
			t.Errorf("parseQuery(%q) = %+v, want kind %d dir %q segment %q", c.q, got, c.kind, c.dir, c.segment)
		}
	}
}

func TestFolderRequestKeepsLocationsAndJoinsRelativePaths(t *testing.T) {
	for _, c := range []struct{ workspace, typed, want string }{
		{"/w", "chernobog:~", "chernobog:~"},
		{"/w", "chernobog:~/proj/", "chernobog:~/proj"},
		{"/w", "chernobog:/", "chernobog:/"},
		{"/w", "chernobog:proj/", "chernobog:~/proj"},
		{"/w", "~/x/", "~/x"},
		{"/w", "src/", "/w/src"},
		{"mayer@chernobog:/home/mayer/proj", "src/", "mayer@chernobog:/home/mayer/proj/src"},
		{"mayer@chernobog:/home/mayer/proj", "../", "mayer@chernobog:/home/mayer"},
	} {
		if got := folderRequest(c.workspace, c.typed); got != c.want {
			t.Errorf("folderRequest(%q, %q) = %q, want %q", c.workspace, c.typed, got, c.want)
		}
	}
}

func TestHostRowsCompleteOnlyWhatTheTextAsksFor(t *testing.T) {
	known := []daemon.KnownHost{
		{Host: "mayer@chernobog", Label: "chernobog", Source: "recent"},
		{Host: "devbox", Label: "devbox", Source: "config"},
	}
	names := func(rows []folderRow) (out []string) {
		for _, r := range rows {
			out = append(out, r.path+"="+r.hostKey)
		}
		return out
	}
	for _, c := range []struct {
		text string
		kind queryKind
		want string
	}{
		{"", queryRecent, ""},
		{"cher", queryRecent, "chernobog:=mayer@chernobog"},
		// a bare word is a prefix, never a fuzzy match, so local filtering
		// does not fill with hosts
		{"cb", queryRecent, ""},
		{"@", queryHosts, "chernobog:=mayer@chernobog devbox:=devbox"},
		{"@dev", queryHosts, "devbox:=devbox"},
		{"root@cher", queryHosts, "root@chernobog:=root@chernobog"},
	} {
		if got := strings.Join(names(hostRows(c.kind, c.text, known)), " "); got != c.want {
			t.Errorf("hostRows(%q) = %q, want %q", c.text, got, c.want)
		}
	}
}

// fakeFolders answers the picker the way the daemon does for one local
// folder and one remote host.
type fakeFolders struct {
	lists  map[string]daemon.FolderList
	hosts  []daemon.KnownHost
	probe  daemon.HostStatus
	warmed []string
}

func (f *fakeFolders) List(p string) (daemon.FolderList, error) {
	if l, ok := f.lists[p]; ok {
		return l, nil
	}
	return daemon.FolderList{}, errors.New("no such folder")
}
func (f *fakeFolders) Repo(string) (*daemon.Repo, error) { return nil, nil }
func (f *fakeFolders) Preview(p string) (daemon.FolderPreview, error) {
	return daemon.FolderPreview{Path: p}, nil
}
func (f *fakeFolders) Sessions() ([]daemon.Session, error) {
	label := "chernobog"
	return []daemon.Session{
		{ID: "a", Workspace: "/Users/dawn/proj/albedo"},
		{ID: "b", Workspace: "mayer@chernobog:/home/mayer/proj/albedo", Location: &daemon.Location{Label: &label}},
	}, nil
}
func (f *fakeFolders) Move(id, workspace string) (daemon.Session, error) {
	return daemon.Session{ID: id, Workspace: workspace}, nil
}
func (f *fakeFolders) Hosts() ([]daemon.KnownHost, error) { return f.hosts, nil }
func (f *fakeFolders) Host(string) (daemon.HostStatus, error) {
	return f.probe, nil
}
func (f *fakeFolders) Warm(h string) (daemon.HostStatus, error) {
	f.warmed = append(f.warmed, h)
	return f.probe, nil
}
func (f *fakeFolders) Local() bool { return true }

// settle runs the picker's commands until it waits on nothing but timers,
// which it drops: previews and polls are not what these tests are about.
func settle(t *testing.T, m FolderPicker, cmd tea.Cmd) FolderPicker {
	t.Helper()
	queue := []tea.Cmd{cmd}
	for len(queue) > 0 {
		next := queue[0]
		queue = queue[1:]
		if next == nil {
			continue
		}
		done := make(chan tea.Msg, 1)
		go func() { done <- next() }()
		var msg tea.Msg
		select {
		case msg = <-done:
		case <-time.After(100 * time.Millisecond):
			continue // a tick
		}
		if batch, ok := msg.(tea.BatchMsg); ok {
			queue = append(queue, batch...)
			continue
		}
		if msg == nil {
			continue
		}
		var more tea.Cmd
		m, more = m.Update(msg)
		queue = append(queue, more)
	}
	return m
}

func typeQuery(t *testing.T, m FolderPicker, text string) FolderPicker {
	for _, r := range text {
		var cmd tea.Cmd
		m, cmd = m.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
		m = settle(t, m, cmd)
	}
	return m
}

func remoteFolders(state, detail string) *fakeFolders {
	return &fakeFolders{
		lists: map[string]daemon.FolderList{
			"chernobog:~":      {Path: "mayer@chernobog:/home/mayer", Home: "mayer@chernobog:/home/mayer", Entries: []daemon.FolderEntry{{Name: "proj"}, {Name: "notes"}}},
			"chernobog:~/proj": {Path: "mayer@chernobog:/home/mayer/proj", Home: "mayer@chernobog:/home/mayer", Entries: []daemon.FolderEntry{{Name: "albedo", VCS: "jj"}}},
		},
		hosts: []daemon.KnownHost{{Host: "mayer@chernobog", Label: "chernobog", Source: "recent"}, {Host: "devbox", Label: "devbox", Source: "config"}},
		probe: daemon.HostStatus{Host: "mayer@chernobog", State: state, Detail: detail, Home: "/home/mayer", OS: "Linux", Arch: "aarch64"},
	}
}

func pickerFrame(m FolderPicker) string {
	return ansi.Strip(m.View())
}

func TestPickerBrowsesAHostFoldingUnderItsHome(t *testing.T) {
	src := remoteFolders("ready", "")
	m := NewFolderPicker(src, daemon.Session{ID: "a", Workspace: "/Users/dawn/proj/albedo"}, nil)
	m.SetSize(100, 16)
	m = settle(t, m, m.Init())

	m = typeQuery(t, m, "chernobog:")
	frame := pickerFrame(m)
	if !strings.Contains(frame, "in chernobog:~") || !strings.Contains(frame, "proj") || !strings.Contains(frame, "notes") {
		t.Fatalf("chernobog: did not list the host's home:\n%s", frame)
	}
	// tab enters the highlighted folder in the host's own ~
	m = settle(t, m, func() tea.Cmd { var c tea.Cmd; m, c = m.Update(tea.KeyPressMsg{Code: tea.KeyDown}); return c }())
	var cmd tea.Cmd
	m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyUp})
	m = settle(t, m, cmd)
	m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyTab})
	m = settle(t, m, cmd)
	if got := m.input.Value(); got != "chernobog:~/proj/" {
		t.Fatalf("tab went to %q", got)
	}
	if frame := pickerFrame(m); !strings.Contains(frame, "in chernobog:~/proj") || !strings.Contains(frame, "albedo") {
		t.Fatalf("the host's folder did not list:\n%s", frame)
	}
	// shift+tab goes back up through the canonical path, still folded
	m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyTab, Mod: tea.ModShift})
	m = settle(t, m, cmd)
	if got := m.input.Value(); got != "chernobog:~/" {
		t.Fatalf("shift+tab went to %q", got)
	}
	// enter moves the session to the canonical location
	m = typeQuery(t, m, "pro")
	m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	moved, ok := cmd().(FolderMovedMsg)
	if !ok || moved.Workspace != "mayer@chernobog:/home/mayer/proj" {
		t.Fatalf("enter moved to %#v", moved)
	}
	// back among the recent folders, the remote one reads like the preview's rule
	m.setQuery("")
	m.cursor = slices.IndexFunc(m.rows, func(r folderRow) bool { return r.hostKey != "" })
	if row := m.row(m.rows[m.cursor], false, false, false, 60, time.Now()); !strings.Contains(ansi.Strip(row), "chernobog:~ › p") {
		t.Fatalf("a recent remote folder's where should lead with host:~: %q", ansi.Strip(row))
	}
	if len(src.warmed) != 1 {
		t.Fatalf("the host was warmed %d times, want once: %v", len(src.warmed), src.warmed)
	}
}

func TestPickerCompletesHostsAndRefusesADeadOne(t *testing.T) {
	src := remoteFolders("unsupported", "needs python >= 3.11")
	m := NewFolderBrowser(src, "/Users/dawn/proj/albedo", "")
	m.SetSize(140, 16)
	m = settle(t, m, m.Init())

	m = typeQuery(t, m, "@")
	frame := pickerFrame(m)
	if !strings.Contains(frame, "chernobog") || !strings.Contains(frame, "devbox") || !strings.Contains(frame, "ssh config") {
		t.Fatalf("@ did not list the known hosts:\n%s", frame)
	}
	// highlighting the host warmed it, and the row says why it is no good
	if !strings.Contains(frame, "needs python >= 3.11") {
		t.Fatalf("the dead host's row does not say why:\n%s", frame)
	}

	// the recent remote folder is the same host: enter refuses it
	m = NewFolderBrowser(src, "/Users/dawn/proj/albedo", "")
	m.SetSize(100, 16)
	m = settle(t, m, m.Init())
	for range 3 {
		if row, _ := m.highlighted(); row.hostKey != "" {
			break
		}
		var cmd tea.Cmd
		m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
		m = settle(t, m, cmd)
	}
	var cmd tea.Cmd
	m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if cmd != nil {
		if _, started := cmd().(FolderNewSessionMsg); started {
			t.Fatalf("enter started a session on a dead host")
		}
	}
	if !strings.Contains(m.notice, "needs python >= 3.11") {
		t.Fatalf("enter did not say why: %q", m.notice)
	}
}

func TestConnectingFaceMovesUntilTheHostSettles(t *testing.T) {
	m := NewFolderBrowser(remoteFolders("warming", ""), "/Users/dawn/proj/albedo", "")
	m.SetSize(140, 16)
	m = settle(t, m, m.Init())
	m = typeQuery(t, m, "cher")
	shows := func(frame int) bool {
		return strings.Contains(pickerFrame(m), "connecting to chernobog… "+connectingFace("chernobog", frame))
	}
	if !shows(m.frame) {
		t.Fatalf("a warming host shows no face:\n%s", pickerFrame(m))
	}
	before := m.frame
	if m, _ = m.Update(connectTickMsg{Gen: m.sessionsGeneration + 1}); m.frame != before {
		t.Fatal("a closed picker's tick moved the face")
	}
	var cmd tea.Cmd
	if m, cmd = m.Update(connectTickMsg{Gen: m.sessionsGeneration}); m.frame != before+1 || cmd == nil || !shows(m.frame) {
		t.Fatalf("the tick did not move the face on (frame %d, next tick %v)", m.frame, cmd != nil)
	}
	m, _ = m.Update(hostStatusMsg{Host: "mayer@chernobog", Status: daemon.HostStatus{Host: "mayer@chernobog", State: "ready"}, Warmed: true})
	if _, cmd = m.Update(connectTickMsg{Gen: m.sessionsGeneration}); cmd != nil {
		t.Fatal("the face kept ticking after the host settled")
	}
}

func TestPickerSaysWhenItCopiesTheKernelOver(t *testing.T) {
	src := remoteFolders("warming", "")
	src.probe.Step = "staging"
	m := NewFolderBrowser(src, "/Users/dawn/proj/albedo", "")
	m.SetSize(140, 16)
	m = settle(t, m, m.Init())
	m = typeQuery(t, m, "cher")
	m, _ = m.Update(hostStatusMsg{Host: "mayer@chernobog", Status: src.probe})
	if frame := pickerFrame(m); !strings.Contains(frame, "copying the kernel to chernobog… ") {
		t.Fatalf("a probe staging the bundle does not say so:\n%s", frame)
	}
}

func TestPickerOffersSignInForAHostThatNeedsAPerson(t *testing.T) {
	src := remoteFolders("needs_auth", "Permission denied (publickey)")
	m := NewFolderBrowser(src, "/Users/dawn/proj/albedo", "")
	m.SetSize(100, 16)
	m = settle(t, m, m.Init())
	m = typeQuery(t, m, "cher")
	frame := pickerFrame(m)
	if !strings.Contains(frame, "sign in · ctrl+l") {
		t.Fatalf("the host row does not offer to sign in:\n%s", frame)
	}
	// without the daemon's control path there is nothing to open here
	var cmd tea.Cmd
	m, cmd = m.Update(tea.KeyPressMsg{Code: 'l', Mod: tea.ModCtrl})
	if cmd != nil || !strings.Contains(m.notice, "ssh mayer@chernobog") {
		t.Fatalf("ctrl+l without a control path: cmd %v, notice %q", cmd != nil, m.notice)
	}
}
