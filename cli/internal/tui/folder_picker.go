package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"strings"
	"time"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
)

// WorkspaceRetry is a turn refused because the session's folder had gone
// missing; it goes out again once the session moves.
type WorkspaceRetry struct {
	Images   []daemon.ImageAttachment
	Pastes   []string
	Missing  string
	Prompt   string
	Continue bool
}

// FolderMovedMsg is the daemon's answer to moving a session.
type FolderMovedMsg struct {
	Err       error
	Retry     *WorkspaceRetry
	SessionID string
	Workspace string
	Location  *daemon.Location
	Session   *daemon.Session
}

type FolderPickerCancelMsg struct{}

// FolderOpenSessionMsg opens a session picked from a folder's preview.
type FolderOpenSessionMsg struct{ Session daemon.Session }

// FolderNewSessionMsg starts a session in a folder picked while browsing.
type FolderNewSessionMsg struct{ Workspace string }

type folderListMsg struct {
	Gen  int64
	Err  error
	Path string
	List daemon.FolderList
}

type folderRepoMsg struct {
	Gen  int64
	Repo *daemon.Repo
	Path string
}

type folderPreviewMsg struct {
	Gen     int64
	Err     error
	Path    string
	Preview daemon.FolderPreview
}

type folderPreviewTickMsg struct {
	Path string
	Gen  int64
}

type hostsMsg struct {
	Gen   int64
	Err   error
	Hosts []daemon.KnownHost
}

// hostStatusMsg is a host's probe as the daemon answered it; Warmed marks
// the answer to warming it, which has always settled.
type hostStatusMsg struct {
	Gen    int64
	Err    error
	Host   string
	Status daemon.HostStatus
	Warmed bool
}

type hostPollMsg struct {
	Host string
	Gen  int64
}

// connectTickMsg advances the connecting face; Gen is the picker's, so a
// closed picker's tick never speeds up the next one.
type connectTickMsg struct{ Gen int64 }

type hostSignedInMsg struct {
	Gen  int64
	Err  error
	Host string
}

type folderSessionsMsg struct {
	Err      error
	Sessions []daemon.Session
	Gen      int64
}

const (
	// queryRecent filters the recent folders, and offers hosts the text
	// starts.
	queryRecent queryKind = iota
	// queryHosts completes a [user@]host before its colon.
	queryHosts
	// queryListing lists a folder, here or on a host.
	queryListing
)

// folderRow is one folder in the picker's list.
type folderRow struct {
	age        *int64
	path, name string
	// host labels a remote folder's host.
	host string
	// hostKey is the [user@]host a remote row is reached through.
	hostKey string
	// source is where a host row's host is known from: recent or config.
	source  string
	matched []int
	// recent rows show where the folder is beside its name.
	recent bool
	// repo says the folder may be in a repository worth asking about.
	repo bool
	// hostRow is a host to complete, not a folder.
	hostRow bool
}

type cachedFolderPreview struct {
	daemon.FolderPreview
	loading, err bool
}

// FolderPicker moves a session to another folder: recent workspaces, or a
// typed path listed through the daemon, beside a preview of the highlighted
// folder. Browsing, from the sessions view, it starts a session in the
// folder instead. Either way → steps into the folder's sessions to open one.
type FolderPicker struct {
	readCtx     context.Context
	cancelReads context.CancelFunc
	src         folderSource
	asked       map[string]bool
	retry       *WorkspaceRetry
	previews    map[string]*cachedFolderPreview
	repos       map[string]*daemon.Repo
	listings    map[string]*folderListMsg

	// session is the one being moved; browsing, only its workspace is set.
	session daemon.Session
	// Session failures survive query edits; a reopened picker rejects the old load.
	sessionsError string
	// homes are the folders ~ names: the daemon's under "", a remote
	// host's under its [user@]host, as listings and probes report them.
	homes map[string]string
	// labels are how hosts read, by [user@]host; aliases name the host a
	// typed one turned out to be.
	labels  map[string]string
	aliases map[string]string
	hosts   []daemon.KnownHost
	// probes are hosts' reachability, warmed once each per picker.
	probes   map[string]daemon.HostStatus
	warmed   map[string]bool
	section  string
	listed   string
	notice   string
	sessions []daemon.Session

	rows               []folderRow
	input              textinput.Model
	sessionsGeneration int64
	Width, Height      int
	cursor             int
	sessionCursor      int
	browse             bool

	sessionsLoading bool
	moving          bool

	// inSessions moves the cursor through the highlighted folder's sessions.
	inSessions bool

	// frame animates the face beside a host still connecting; ticking is
	// whether its next tick is already on its way.
	frame   int
	ticking bool
}

func NewFolderPicker(src folderSource, session daemon.Session, retry *WorkspaceRetry) FolderPicker {
	ti := newTextInput()
	ti.Prompt = ""
	ti.Placeholder = "Type a path or choose a folder"
	st := ti.Styles()
	st.Focused.Placeholder, st.Blurred.Placeholder = DefaultStyles.Faint, DefaultStyles.Faint
	ti.SetStyles(st)
	ti.Focus()
	readCtx, cancelReads := context.WithCancel(context.Background())
	m := FolderPicker{
		readCtx:            readCtx,
		cancelReads:        cancelReads,
		input:              ti,
		session:            session,
		retry:              retry,
		src:                src,
		listings:           map[string]*folderListMsg{},
		repos:              map[string]*daemon.Repo{},
		asked:              map[string]bool{},
		previews:           map[string]*cachedFolderPreview{},
		homes:              map[string]string{},
		labels:             map[string]string{},
		aliases:            map[string]string{},
		probes:             map[string]daemon.HostStatus{},
		warmed:             map[string]bool{},
		sessionsLoading:    true,
		sessionsGeneration: int64(nextPageGeneration()),
	}
	m.rebuild()
	return m
}

// NewFolderBrowser picks a folder to start a session in or to open one of
// its sessions, starting from query.
func NewFolderBrowser(src folderSource, workspace, query string) FolderPicker {
	m := NewFolderPicker(src, daemon.Session{Workspace: workspace}, nil)
	m.browse = true
	m.setQuery(query)
	return m
}

func (m *FolderPicker) SetSize(width, height int) {
	m.Width, m.Height = width, height
	m.input.SetWidth(max(1, width-8))
}

func (m *FolderPicker) Close() {
	if m.cancelReads != nil {
		m.cancelReads()
	}
	m.sessionsGeneration = int64(nextPageGeneration())
}

func (m FolderPicker) Init() tea.Cmd {
	return tea.Batch(m.loadSessionsCmd(), m.loadHostsCmd(), m.fetch(), m.previewCmd())
}

func (m FolderPicker) Update(msg tea.Msg) (FolderPicker, tea.Cmd) {
	switch msg := msg.(type) {
	case folderSessionsMsg:
		if msg.Gen != m.sessionsGeneration {
			return m, nil
		}
		m.sessionsLoading = false
		if msg.Err != nil {
			m.sessionsError = msg.Err.Error()
			return m, nil
		}
		m.sessionsError = ""
		m.sessions, m.inSessions = msg.Sessions, false
		for _, s := range m.sessions {
			if host, _ := daemon.SplitLocation(s.Workspace); host != "" && m.labels[host] == "" {
				m.labels[host] = sessionHost(s)
			}
		}
		if parseQuery(m.input.Value()).kind != queryListing {
			m.cursor = -1 // nothing was there to pick yet
			m.rebuild()
		}
	case hostsMsg:
		if msg.Gen != m.sessionsGeneration {
			return m, nil
		}
		if msg.Err != nil {
			return m, nil // a daemon without the list still has the sessions' hosts
		}
		m.hosts = msg.Hosts
		for _, h := range m.hosts {
			if h.Label != "" {
				m.labels[h.Host] = h.Label
			}
		}
		if parseQuery(m.input.Value()).kind != queryListing {
			m.rebuild()
		}
	case hostPollMsg:
		if msg.Gen != m.sessionsGeneration {
			return m, nil
		}
		if m.probe(msg.Host).State != "warming" {
			return m, nil
		}
		src, ctx, gen, h := m.src, m.readCtx, m.sessionsGeneration, msg.Host
		return m, func() tea.Msg {
			status, err := src.Host(ctx, h)
			return hostStatusMsg{Gen: gen, Host: h, Status: status, Err: err}
		}
	case hostStatusMsg:
		if msg.Gen != m.sessionsGeneration {
			return m, nil
		}
		return m, m.probed(msg)
	case connectTickMsg:
		if msg.Gen != m.sessionsGeneration {
			return m, nil
		}
		m.ticking = false
		m.frame++
		return m, m.tick()
	case hostSignedInMsg:
		if msg.Gen != m.sessionsGeneration {
			return m, nil
		}
		if msg.Err != nil {
			m.notice = "Signing in to " + m.labelOf(msg.Host) + " failed: " + msg.Err.Error()
			return m, nil
		}
		m.warmed[msg.Host], m.warmed[m.canonical(msg.Host)] = false, false
		return m, m.warm(msg.Host)
	case folderListMsg:
		if msg.Gen != m.sessionsGeneration {
			return m, nil
		}
		m.listings[msg.Path] = &msg
		if msg.Err == nil {
			m.learnHome(msg.Path, msg.List)
		}
		if msg.Path == m.listed {
			m.rebuild()
		}
	case folderRepoMsg:
		if msg.Gen != m.sessionsGeneration {
			return m, nil
		}
		m.repos[msg.Path] = msg.Repo
		return m, nil
	case folderPreviewMsg:
		if msg.Gen != m.sessionsGeneration {
			return m, nil
		}
		if c := m.previews[msg.Path]; c != nil {
			c.loading, c.err = false, msg.Err != nil
			c.FolderPreview = msg.Preview
		}
		return m, nil
	case folderPreviewTickMsg:
		if msg.Gen != m.sessionsGeneration {
			return m, nil
		}
		if row, ok := m.highlighted(); ok && row.path == msg.Path {
			return m, m.fetchPreview(msg.Path)
		}
		return m, nil
	case tea.KeyPressMsg:
		if m.moving {
			return m, nil
		}
		if msg.String() == "ctrl+r" && m.sessionsError != "" {
			if m.sessionsLoading {
				return m, nil
			}
			m.sessionsLoading = true
			return m, m.loadSessionsCmd()
		}
		if m.inSessions {
			if cmd, done := m.sessionKey(msg); done {
				return m, cmd
			}
		}
		switch msg.String() {
		case "esc", "ctrl+c":
			return m, func() tea.Msg { return FolderPickerCancelMsg{} }
		case "ctrl+l":
			if row, ok := m.highlighted(); ok && m.probe(row.hostKey).State == "needs_auth" {
				return m, m.signIn(row.hostKey)
			}
		case "up", "ctrl+p":
			m.cursor = max(0, m.cursor-1)
		case "down", "ctrl+n":
			m.cursor = max(0, min(len(m.rows)-1, m.cursor+1))
		case "tab":
			if row, ok := m.highlighted(); ok && row.hostRow {
				m.setQuery(row.path)
			} else if ok {
				m.setQuery(m.homed(row.path) + "/")
			}
		case "shift+tab":
			m.setQuery(m.parentQuery())
		case "right":
			row, _ := m.highlighted()
			if m.input.Position() < len([]rune(m.input.Value())) || len(m.sessionsIn(row.path)) == 0 {
				return m.typed(msg)
			}
			m.inSessions, m.sessionCursor = true, 0
		case "enter":
			if row, ok := m.highlighted(); ok && row.hostRow {
				m.setQuery(row.path)
				break
			}
			return m, m.move()
		default:
			return m.typed(msg)
		}
	case tea.PasteMsg:
		return m.typed(msg)
	}
	return m, m.follow()
}

// follow asks for what the list now shows: the listing, repositories and
// the preview, and warms the hosts it reaches.
func (m *FolderPicker) follow() tea.Cmd {
	return tea.Batch(m.fetch(), m.previewCmd(), m.warmShown())
}

// hostPollEvery is how often a warming host is asked again.
const hostPollEvery = 750 * time.Millisecond

// sessionKey moves through the highlighted folder's sessions; done is false
// for a key that leaves them for the folder list, which then handles it.
func (m *FolderPicker) sessionKey(msg tea.KeyPressMsg) (cmd tea.Cmd, done bool) {
	row, _ := m.highlighted()
	sessions := m.sessionsIn(row.path)
	switch msg.String() {
	case "up", "ctrl+p":
		m.sessionCursor = max(0, m.sessionCursor-1)
	case "down", "ctrl+n":
		m.sessionCursor = max(0, min(len(sessions)-1, m.sessionCursor+1))
	case "enter":
		if m.sessionCursor < len(sessions) {
			s := sessions[m.sessionCursor]
			return func() tea.Msg { return FolderOpenSessionMsg{Session: s} }, true
		}
	case "left", "esc":
		m.inSessions = false
	default:
		m.inSessions = false
		return nil, false
	}
	return nil, true
}

// typed hands msg to the query and lists what it asks for now.
func (m FolderPicker) typed(msg tea.Msg) (FolderPicker, tea.Cmd) {
	value := m.input.Value()
	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	if m.input.Value() != value {
		m.notice = ""
		m.rebuild()
	}
	return m, tea.Batch(cmd, m.follow())
}

func (m *FolderPicker) setQuery(q string) {
	m.input.SetValue(q)
	m.input.CursorEnd()
	m.notice = ""
	m.rebuild()
}

func (m *FolderPicker) move() tea.Cmd {
	target := m.target()
	host, _ := daemon.SplitLocation(target)
	probe := m.probe(host)
	switch {
	case target == "":
		return nil
	case probe.State == "unreachable" || probe.State == "unsupported":
		m.notice = m.labelOf(host) + ": " + cmp.Or(probe.Detail, strings.ReplaceAll(probe.State, "_", " "))
		return nil
	case probe.State == "needs_auth":
		m.notice = "Sign in to " + m.labelOf(host) + " first · ctrl+l"
		return nil
	case m.browse:
		return func() tea.Msg { return FolderNewSessionMsg{Workspace: target} }
	case target == m.workspace() && m.retry == nil:
		return func() tea.Msg { return FolderPickerCancelMsg{} }
	}
	m.moving, m.notice = true, ""
	return moveCmd(m.src, m.session.ID, m.workspace(), target, m.retry)
}

// Refused shows why the daemon would not move the session and lets you
// pick again.
func (m *FolderPicker) Refused(err error) {
	m.moving, m.notice = false, err.Error()
}
