package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"path"
	"slices"
	"strings"
	"time"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"github.com/sahilm/fuzzy"
)

// folderSource is what the folder picker asks the daemon.
type folderSource interface {
	List(path string) (daemon.FolderList, error)
	Repo(path string) (*daemon.Repo, error)
	Preview(path string) (daemon.FolderPreview, error)
	Sessions() ([]daemon.Session, error)
	Move(id, workspace string) (daemon.Session, error)
}

// daemonFolders is a folderSource over a daemon connection.
type daemonFolders struct{ conn *daemon.Connection }

func (d daemonFolders) List(p string) (daemon.FolderList, error) {
	return daemon.ListFolders(context.Background(), d.conn, p)
}

func (d daemonFolders) Repo(p string) (*daemon.Repo, error) {
	return daemon.FolderRepo(context.Background(), d.conn, p)
}

func (d daemonFolders) Preview(p string) (daemon.FolderPreview, error) {
	return daemon.PreviewFolder(context.Background(), d.conn, p)
}

func (d daemonFolders) Sessions() ([]daemon.Session, error) {
	return daemon.Request[[]daemon.Session](context.Background(), d.conn, "/sessions", nil)
}

func (d daemonFolders) Move(id, workspace string) (daemon.Session, error) {
	return daemon.MoveSession(context.Background(), d.conn, id, workspace)
}

// WorkspaceRetry is a turn refused because the session's folder had gone
// missing; it goes out again once the session moves.
type WorkspaceRetry struct {
	Missing  string
	Prompt   string
	Continue bool
	Image    *daemon.ImageAttachment
}

// FolderMovedMsg is the daemon's answer to moving a session.
type FolderMovedMsg struct {
	SessionID string
	Workspace string
	Retry     *WorkspaceRetry
	Err       error
}

type FolderPickerCancelMsg struct{}

// FolderOpenSessionMsg opens a session picked from a folder's preview.
type FolderOpenSessionMsg struct{ Session daemon.Session }

// FolderNewSessionMsg starts a session in a folder picked while browsing.
type FolderNewSessionMsg struct{ Workspace string }

type folderListMsg struct {
	Path string
	List daemon.FolderList
	Err  error
}

type folderRepoMsg struct {
	Path string
	Repo *daemon.Repo
}

type folderPreviewMsg struct {
	Path    string
	Preview daemon.FolderPreview
	Err     error
}

type folderPreviewTickMsg struct{ Path string }

type folderSessionsMsg struct{ Sessions []daemon.Session }

// moveCmd moves session id to input: absolute, under ~, or relative to
// the folder it is in now. The daemon names the folder a ~ or relative
// path is, and whether it exists.
func moveCmd(src folderSource, id, workspace, input string, retry *WorkspaceRetry) tea.Cmd {
	return func() tea.Msg {
		target := folderRequest(workspace, input)
		if !strings.HasPrefix(target, "/") {
			list, err := src.List(target)
			if err != nil {
				return FolderMovedMsg{SessionID: id, Retry: retry, Err: err}
			}
			target = list.Path
		}
		s, err := src.Move(id, target)
		return FolderMovedMsg{SessionID: id, Workspace: cmp.Or(s.Workspace, target), Retry: retry, Err: err}
	}
}

// folderRequest is how the daemon is asked about a typed folder: ~ and
// absolute paths as they are, anything else under the current folder.
func folderRequest(workspace, typed string) string {
	if typed != "/" {
		typed = strings.TrimSuffix(typed, "/")
	}
	if strings.HasPrefix(typed, "/") || typed == "~" || strings.HasPrefix(typed, "~/") {
		return typed
	}
	return path.Join(workspace, typed)
}

// splitQuery reads a typed path as the folder to list and the segment that
// filters it. Text without a slash filters the recent folders instead.
func splitQuery(q string) (dir, segment string, listing bool) {
	if q == "~" {
		return "~", "", true
	}
	i := strings.LastIndex(q, "/")
	if i < 0 {
		return "", q, false
	}
	return q[:i+1], q[i+1:], true
}

// frecency weighs each session in a folder by how recently it was used, so
// a folder you work in daily outranks one you used often long ago: 4 within
// the hour, halving past a day, a week and a month.
func frecency(last *int64, now time.Time) float64 {
	weight := 4.0
	for _, within := range []time.Duration{time.Hour, 24 * time.Hour, 7 * 24 * time.Hour, 30 * 24 * time.Hour} {
		if last != nil && now.Sub(time.Unix(*last, 0)) < within {
			return weight
		}
		weight /= 2
	}
	return weight
}

type recentFolder struct {
	path  string
	last  *int64
	score float64
}

// recentFolders are the distinct workspaces of sessions, most frecent
// first, with the current one leading.
func recentFolders(sessions []daemon.Session, current string, now time.Time) []recentFolder {
	index := map[string]int{}
	var out []recentFolder
	for _, s := range sessions {
		if s.Workspace == "" {
			continue
		}
		i, ok := index[s.Workspace]
		if !ok {
			i, index[s.Workspace] = len(out), len(out)
			out = append(out, recentFolder{path: s.Workspace})
		}
		f := &out[i]
		f.score += frecency(s.LastAssistantAt, now)
		if s.LastAssistantAt != nil && (f.last == nil || *s.LastAssistantAt > *f.last) {
			f.last = s.LastAssistantAt
		}
	}
	if _, ok := index[current]; !ok && current != "" {
		out = append(out, recentFolder{path: current})
	}
	slices.SortStableFunc(out, func(a, b recentFolder) int {
		switch {
		case a.path == current:
			return -1
		case b.path == current:
			return 1
		}
		return cmp.Compare(b.score, a.score)
	})
	return out
}

// fuzzyNames matches segment against names, best first; an empty segment
// keeps them all in order.
func fuzzyNames(segment string, names []string) []fuzzy.Match {
	if segment == "" {
		all := make([]fuzzy.Match, len(names))
		for i, n := range names {
			all[i] = fuzzy.Match{Str: n, Index: i}
		}
		return all
	}
	return fuzzy.Find(segment, names)
}

// folderRow is one folder in the picker's list.
type folderRow struct {
	path, name string
	// recent rows show where the folder is beside its name.
	recent  bool
	matched []int
	age     *int64
	// repo says the folder may be in a repository worth asking about.
	repo bool
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
	Width, Height int
	input         textinput.Model

	// session is the one being moved; browsing, only its workspace is set.
	session  daemon.Session
	browse   bool
	retry    *WorkspaceRetry
	src      folderSource
	sessions []daemon.Session
	// home is the daemon's home, which ~ names, once a listing reports it.
	home string

	rows     []folderRow
	cursor   int
	section  string
	listed   string
	listings map[string]*folderListMsg
	repos    map[string]*daemon.Repo
	asked    map[string]bool
	previews map[string]*cachedFolderPreview

	moving bool
	notice string

	// inSessions moves the cursor through the highlighted folder's sessions.
	inSessions    bool
	sessionCursor int
}

func NewFolderPicker(src folderSource, session daemon.Session, retry *WorkspaceRetry) FolderPicker {
	ti := newTextInput()
	ti.Prompt = ""
	ti.Placeholder = "Type a path or choose a folder"
	st := ti.Styles()
	st.Focused.Placeholder, st.Blurred.Placeholder = DefaultStyles.Faint, DefaultStyles.Faint
	ti.SetStyles(st)
	ti.Focus()
	m := FolderPicker{
		input:    ti,
		session:  session,
		retry:    retry,
		src:      src,
		listings: map[string]*folderListMsg{},
		repos:    map[string]*daemon.Repo{},
		asked:    map[string]bool{},
		previews: map[string]*cachedFolderPreview{},
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

func (m FolderPicker) Init() tea.Cmd {
	src := m.src
	return tea.Batch(func() tea.Msg {
		sessions, _ := src.Sessions()
		return folderSessionsMsg{Sessions: sessions}
	}, m.fetch(), m.previewCmd())
}

func (m FolderPicker) workspace() string { return m.session.Workspace }

// homed shortens p under the daemon's home to start with ~.
func (m FolderPicker) homed(p string) string {
	if m.home == "" {
		return homePath(p)
	}
	return underHome(p, m.home)
}

// listing is the typed folder's listing, once it has arrived without error.
func (m FolderPicker) listing() (daemon.FolderList, bool) {
	if l := m.listings[m.listed]; l != nil && l.Err == nil {
		return l.List, true
	}
	return daemon.FolderList{}, false
}

func (m FolderPicker) highlighted() (folderRow, bool) {
	if m.cursor >= 0 && m.cursor < len(m.rows) {
		return m.rows[m.cursor], true
	}
	return folderRow{}, false
}

// rebuild lists what the query asks for: recent folders, or the typed
// folder's directories filtered by the last segment.
func (m *FolderPicker) rebuild() {
	before, _ := m.highlighted()
	dir, segment, listing := splitQuery(m.input.Value())
	m.rows, m.listed = nil, ""
	var candidates []folderRow
	if !listing {
		m.section = "recent"
		for _, f := range recentFolders(m.sessions, m.workspace(), time.Now()) {
			candidates = append(candidates, folderRow{path: f.path, name: path.Base(f.path), recent: true, age: f.last, repo: true})
		}
	} else {
		m.listed = folderRequest(m.workspace(), dir)
		m.section = "in " + m.homed(m.listed)
		if l, ok := m.listing(); ok {
			m.section = "in " + m.homed(l.Path)
			for _, e := range l.Entries {
				if e.Hidden && !strings.HasPrefix(segment, ".") {
					continue
				}
				row := folderRow{path: path.Join(l.Path, e.Name), name: e.Name, repo: e.VCS != ""}
				if e.Modified > 0 {
					row.age = &e.Modified
				}
				candidates = append(candidates, row)
			}
		}
	}
	names := make([]string, len(candidates))
	for i, row := range candidates {
		names[i] = row.name
	}
	for _, match := range fuzzyNames(segment, names) {
		row := candidates[match.Index]
		row.matched = match.MatchedIndexes
		m.rows = append(m.rows, row)
	}
	m.cursor = 0
	if i := slices.IndexFunc(m.rows, func(r folderRow) bool { return r.path == before.path }); i >= 0 {
		m.cursor = i
	} else if !listing && segment == "" && len(m.rows) > 1 && !m.browse {
		m.cursor = 1 // the current folder leads; the likeliest move is the next
	}
}

func (m FolderPicker) Update(msg tea.Msg) (FolderPicker, tea.Cmd) {
	switch msg := msg.(type) {
	case folderSessionsMsg:
		m.sessions, m.inSessions = msg.Sessions, false
		if _, _, listing := splitQuery(m.input.Value()); !listing {
			m.cursor = -1 // nothing was there to pick yet
			m.rebuild()
		}
	case folderListMsg:
		m.listings[msg.Path] = &msg
		if msg.Err == nil && msg.List.Home != "" {
			m.home = msg.List.Home
		}
		if msg.Path == m.listed {
			m.rebuild()
		}
	case folderRepoMsg:
		m.repos[msg.Path] = msg.Repo
		return m, nil
	case folderPreviewMsg:
		if c := m.previews[msg.Path]; c != nil {
			c.loading, c.err = false, msg.Err != nil
			c.FolderPreview = msg.Preview
		}
		return m, nil
	case folderPreviewTickMsg:
		if row, ok := m.highlighted(); ok && row.path == msg.Path {
			return m, m.fetchPreview(msg.Path)
		}
		return m, nil
	case tea.KeyPressMsg:
		if m.moving {
			return m, nil
		}
		if m.inSessions {
			if cmd, done := m.sessionKey(msg); done {
				return m, cmd
			}
		}
		switch msg.String() {
		case "esc", "ctrl+c":
			return m, func() tea.Msg { return FolderPickerCancelMsg{} }
		case "up", "ctrl+p":
			m.cursor = max(0, m.cursor-1)
		case "down", "ctrl+n":
			m.cursor = max(0, min(len(m.rows)-1, m.cursor+1))
		case "tab":
			if row, ok := m.highlighted(); ok {
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
			return m, m.move()
		default:
			return m.typed(msg)
		}
	case tea.PasteMsg:
		return m.typed(msg)
	}
	return m, tea.Batch(m.fetch(), m.previewCmd())
}

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
	return m, tea.Batch(cmd, m.fetch(), m.previewCmd())
}

func (m *FolderPicker) setQuery(q string) {
	m.input.SetValue(q)
	m.input.CursorEnd()
	m.notice = ""
	m.rebuild()
}

// parentQuery is the folder above the one being listed, or above the
// session's folder when nothing is typed.
func (m FolderPicker) parentQuery() string {
	dir := m.workspace()
	if m.listed != "" {
		dir = m.listed
		if l, ok := m.listing(); ok {
			dir = l.Path
		}
	}
	up := m.homed(path.Dir(dir))
	return pick(up == "/", "/", up+"/")
}

// target is the folder enter moves to: the highlighted row, or the typed
// folder itself when it has nothing left to pick.
func (m FolderPicker) target() string {
	if row, ok := m.highlighted(); ok {
		return row.path
	}
	if _, segment, listing := splitQuery(m.input.Value()); listing && segment == "" {
		if l, ok := m.listing(); ok {
			return l.Path
		}
	}
	return ""
}

func (m *FolderPicker) move() tea.Cmd {
	target := m.target()
	switch {
	case target == "":
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

// fetch asks for the listing being typed and the repositories of the rows
// on screen, each once.
func (m *FolderPicker) fetch() tea.Cmd {
	var cmds []tea.Cmd
	if p := m.listed; p != "" && !m.asked["list:"+p] {
		m.asked["list:"+p] = true
		src := m.src
		cmds = append(cmds, func() tea.Msg {
			list, err := src.List(p)
			return folderListMsg{Path: p, List: list, Err: err}
		})
	}
	first, last := m.visibleRows()
	for _, row := range m.rows[first:last] {
		if !row.repo || m.asked["repo:"+row.path] {
			continue
		}
		m.asked["repo:"+row.path] = true
		src, p := m.src, row.path
		cmds = append(cmds, func() tea.Msg {
			repo, _ := src.Repo(p)
			return folderRepoMsg{Path: p, Repo: repo}
		})
	}
	return tea.Batch(cmds...)
}

// previewCmd asks for the highlighted folder's preview after the same pause
// as the sessions view, so scrolling past a row does not fetch it.
func (m FolderPicker) previewCmd() tea.Cmd {
	row, ok := m.highlighted()
	if !ok || m.previews[row.path] != nil {
		return nil
	}
	p := row.path
	return tea.Tick(previewDebounce, func(time.Time) tea.Msg { return folderPreviewTickMsg{Path: p} })
}

func (m *FolderPicker) fetchPreview(p string) tea.Cmd {
	if m.previews[p] != nil {
		return nil
	}
	m.previews[p] = &cachedFolderPreview{loading: true}
	src := m.src
	return func() tea.Msg {
		preview, err := src.Preview(p)
		return folderPreviewMsg{Path: p, Preview: preview, Err: err}
	}
}
