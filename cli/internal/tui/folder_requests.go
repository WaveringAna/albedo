package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
)

// folderSource is what the folder picker asks the daemon.
type folderSource interface {
	List(ctx context.Context, path string) (daemon.FolderList, error)
	Repo(ctx context.Context, path string) (*daemon.Repo, error)
	Preview(ctx context.Context, path string) (daemon.FolderPreview, error)
	Sessions(ctx context.Context) ([]daemon.Session, error)
	Move(ctx context.Context, id, workspace string) (daemon.Session, error)
	Hosts(ctx context.Context) ([]daemon.KnownHost, error)
	Host(ctx context.Context, host string) (daemon.HostStatus, error)
	Warm(ctx context.Context, host string) (daemon.HostStatus, error)
	// Local says the daemon shares this machine, so an ssh master opened
	// here is one it rides.
	Local() bool
}

// daemonFolders is a folderSource over a daemon connection.
type daemonFolders struct {
	conn      *daemon.Connection
	condition daemon.SessionCondition
}

func (d daemonFolders) List(ctx context.Context, p string) (daemon.FolderList, error) {
	return daemon.ListFolders(ctx, d.conn, p)
}

func (d daemonFolders) Repo(ctx context.Context, p string) (*daemon.Repo, error) {
	return daemon.FolderRepo(ctx, d.conn, p)
}

func (d daemonFolders) Preview(ctx context.Context, p string) (daemon.FolderPreview, error) {
	return daemon.PreviewFolder(ctx, d.conn, p)
}

func (d daemonFolders) Sessions(ctx context.Context) ([]daemon.Session, error) {
	return daemon.ListSessions(ctx, d.conn)
}

func (d daemonFolders) Move(ctx context.Context, id, workspace string) (daemon.Session, error) {
	return daemon.MoveSession(ctx, d.conn, id, workspace, d.condition)
}

func (d daemonFolders) Hosts(ctx context.Context) ([]daemon.KnownHost, error) {
	return daemon.ListHosts(ctx, d.conn)
}

func (d daemonFolders) Host(ctx context.Context, h string) (daemon.HostStatus, error) {
	return daemon.GetHost(ctx, d.conn, h)
}

func (d daemonFolders) Warm(ctx context.Context, h string) (daemon.HostStatus, error) {
	return daemon.WarmHost(ctx, d.conn, h)
}

func (d daemonFolders) Local() bool { return d.conn.Local() }

// moveCmd moves session id to input: absolute, under ~, or relative to
// the folder it is in now. The daemon names the folder a ~ or relative
// path is, and whether it exists.
func moveCmd(src folderSource, id, workspace, input string, retry *WorkspaceRetry) tea.Cmd {
	return func() tea.Msg {
		target := folderRequest(workspace, input)
		if _, _, remote := splitHost(target); !remote && !strings.HasPrefix(target, "/") {
			list, err := src.List(context.Background(), target)
			if err != nil {
				return FolderMovedMsg{SessionID: id, Retry: retry, Err: err}
			}
			target = list.Path
		}
		s, err := src.Move(context.Background(), id, target)
		return FolderMovedMsg{SessionID: id, Workspace: cmp.Or(s.Workspace, target), Location: s.Location, Session: &s, Retry: retry, Err: err}
	}
}

func (m FolderPicker) loadHostsCmd() tea.Cmd {
	src, ctx, gen := m.src, m.readCtx, m.sessionsGeneration
	return func() tea.Msg {
		hosts, err := src.Hosts(ctx)
		return hostsMsg{Gen: gen, Hosts: hosts, Err: err}
	}
}

func (m FolderPicker) loadSessionsCmd() tea.Cmd {
	src, ctx, gen := m.src, m.readCtx, m.sessionsGeneration
	return func() tea.Msg {
		sessions, err := src.Sessions(ctx)
		return folderSessionsMsg{Sessions: sessions, Err: err, Gen: gen}
	}
}

// warmShown warms the host of the highlighted row, and the host a remote
// listing is typed for, once each.
func (m *FolderPicker) warmShown() tea.Cmd {
	var cmds []tea.Cmd
	if row, ok := m.highlighted(); ok {
		cmds = append(cmds, m.warm(row.hostKey))
	}
	if host, _, remote := splitHost(m.listed); remote {
		cmds = append(cmds, m.warm(m.canonical(host)))
	}
	return tea.Batch(cmds...)
}

// warm probes host now and polls its state until the probe settles, once
// per picker, so a dead host shows before it is picked.
func (m *FolderPicker) warm(host string) tea.Cmd {
	if host == "" || m.warmed[host] || m.warmed[m.canonical(host)] {
		return nil
	}
	m.warmed[host] = true
	m.probes[host] = daemon.HostStatus{Host: host, State: "warming"}
	src, ctx, gen := m.src, m.readCtx, m.sessionsGeneration
	return tea.Batch(func() tea.Msg {
		status, err := src.Warm(ctx, host)
		return hostStatusMsg{Gen: gen, Host: host, Status: status, Err: err, Warmed: true}
	}, pollHost(host, m.sessionsGeneration), m.tick())
}

func (m FolderPicker) warming() bool {
	for _, p := range m.probes {
		if p.State == "warming" {
			return true
		}
	}
	return false
}

// tick keeps the connecting face moving while any host still warms.
func (m *FolderPicker) tick() tea.Cmd {
	if m.ticking || !m.warming() {
		return nil
	}
	m.ticking = true
	gen := m.sessionsGeneration
	return tea.Tick(faceInterval, func(time.Time) tea.Msg { return connectTickMsg{Gen: gen} })
}

func pollHost(host string, gen int64) tea.Cmd {
	return tea.Tick(hostPollEvery, func(time.Time) tea.Msg { return hostPollMsg{Gen: gen, Host: host} })
}

// probed takes a host's state. A poll still warming asks again; one that
// lands after the probe settled is stale. A daemon that cannot say leaves
// the host unmarked, and its listing speaks for it.
func (m *FolderPicker) probed(msg hostStatusMsg) tea.Cmd {
	current, ok := m.probes[msg.Host]
	if !ok || current.State != "warming" && !msg.Warmed {
		return nil
	}
	switch {
	case msg.Err != nil:
		if msg.Warmed {
			delete(m.probes, msg.Host)
		}
		return nil
	case msg.Status.State == "warming":
		m.probes[msg.Host] = msg.Status // it may say what the probe is doing
		return pollHost(msg.Host, m.sessionsGeneration)
	}
	m.probes[msg.Host] = msg.Status
	if msg.Status.Home != "" {
		_, home := daemon.SplitLocation(msg.Status.Home)
		m.homes[m.canonical(msg.Host)] = home
	}
	return m.follow()
}

// signIn opens the daemon's ssh master for host in this terminal, the way
// a refused turn does, then warms the host again.
func (m *FolderPicker) signIn(host string) tea.Cmd {
	probe := m.probe(host)
	if !m.src.Local() || probe.ControlPath == "" {
		m.notice = "Run `ssh " + host + "` on the machine albedo runs on, then try again"
		return nil
	}
	gen := m.sessionsGeneration
	return tea.ExecProcess(signInCommand(host, probe.ControlPath), func(err error) tea.Msg {
		return hostSignedInMsg{Gen: gen, Host: host, Err: err}
	})
}

// fetch asks for the listing being typed and the repositories of the rows
// on screen, each once.
func (m *FolderPicker) fetch() tea.Cmd {
	var cmds []tea.Cmd
	if p := m.listed; p != "" && !m.asked["list:"+p] {
		m.asked["list:"+p] = true
		src, ctx, gen := m.src, m.readCtx, m.sessionsGeneration
		cmds = append(cmds, func() tea.Msg {
			list, err := src.List(ctx, p)
			return folderListMsg{Gen: gen, Path: p, List: list, Err: err}
		})
	}
	first, last := m.visibleRows()
	for _, row := range m.rows[first:last] {
		if !row.repo || m.asked["repo:"+row.path] || !m.reachable(row) {
			continue
		}
		m.asked["repo:"+row.path] = true
		src, ctx, gen, p := m.src, m.readCtx, m.sessionsGeneration, row.path
		cmds = append(cmds, func() tea.Msg {
			repo, _ := src.Repo(ctx, p)
			return folderRepoMsg{Gen: gen, Path: p, Repo: repo}
		})
	}
	return tea.Batch(cmds...)
}

// previewCmd asks for the highlighted folder's preview after the same pause
// as the sessions view, so scrolling past a row does not fetch it.
func (m FolderPicker) previewCmd() tea.Cmd {
	row, ok := m.highlighted()
	if !ok || row.hostRow || m.previews[row.path] != nil || !m.reachable(row) {
		return nil
	}
	p, gen := row.path, m.sessionsGeneration
	return tea.Tick(previewDebounce, func(time.Time) tea.Msg { return folderPreviewTickMsg{Gen: gen, Path: p} })
}

func (m *FolderPicker) fetchPreview(p string) tea.Cmd {
	if m.previews[p] != nil {
		return nil
	}
	m.previews[p] = &cachedFolderPreview{loading: true}
	src, ctx, gen := m.src, m.readCtx, m.sessionsGeneration
	return func() tea.Msg {
		preview, err := src.Preview(ctx, p)
		return folderPreviewMsg{Gen: gen, Path: p, Preview: preview, Err: err}
	}
}
