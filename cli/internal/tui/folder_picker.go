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
	Hosts() ([]daemon.KnownHost, error)
	Host(host string) (daemon.HostStatus, error)
	Warm(host string) (daemon.HostStatus, error)
	// Local says the daemon shares this machine, so an ssh master opened
	// here is one it rides.
	Local() bool
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
	return daemon.ListSessions(context.Background(), d.conn)
}

func (d daemonFolders) Move(id, workspace string) (daemon.Session, error) {
	return daemon.MoveSession(context.Background(), d.conn, id, workspace)
}

func (d daemonFolders) Hosts() ([]daemon.KnownHost, error) {
	return daemon.ListHosts(context.Background(), d.conn)
}

func (d daemonFolders) Host(h string) (daemon.HostStatus, error) {
	return daemon.GetHost(context.Background(), d.conn, h)
}

func (d daemonFolders) Warm(h string) (daemon.HostStatus, error) {
	return daemon.WarmHost(context.Background(), d.conn, h)
}

func (d daemonFolders) Local() bool { return d.conn.Local() }

// WorkspaceRetry is a turn refused because the session's folder had gone
// missing; it goes out again once the session moves.
type WorkspaceRetry struct {
	Image    *daemon.ImageAttachment
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
}

type FolderPickerCancelMsg struct{}

// FolderOpenSessionMsg opens a session picked from a folder's preview.
type FolderOpenSessionMsg struct{ Session daemon.Session }

// FolderNewSessionMsg starts a session in a folder picked while browsing.
type FolderNewSessionMsg struct{ Workspace string }

type folderListMsg struct {
	Err  error
	Path string
	List daemon.FolderList
}

type folderRepoMsg struct {
	Repo *daemon.Repo
	Path string
}

type folderPreviewMsg struct {
	Err     error
	Path    string
	Preview daemon.FolderPreview
}

type folderPreviewTickMsg struct{ Path string }

type hostsMsg struct {
	Err   error
	Hosts []daemon.KnownHost
}

// hostStatusMsg is a host's probe as the daemon answered it; Warmed marks
// the answer to warming it, which has always settled.
type hostStatusMsg struct {
	Err    error
	Host   string
	Status daemon.HostStatus
	Warmed bool
}

type hostPollMsg struct{ Host string }

type hostSignedInMsg struct {
	Err  error
	Host string
}

type folderSessionsMsg struct {
	Err      error
	Sessions []daemon.Session
	Gen      int64
}

// moveCmd moves session id to input: absolute, under ~, or relative to
// the folder it is in now. The daemon names the folder a ~ or relative
// path is, and whether it exists.
func moveCmd(src folderSource, id, workspace, input string, retry *WorkspaceRetry) tea.Cmd {
	return func() tea.Msg {
		target := folderRequest(workspace, input)
		if _, _, remote := splitHost(target); !remote && !strings.HasPrefix(target, "/") {
			list, err := src.List(target)
			if err != nil {
				return FolderMovedMsg{SessionID: id, Retry: retry, Err: err}
			}
			target = list.Path
		}
		s, err := src.Move(id, target)
		return FolderMovedMsg{SessionID: id, Workspace: cmp.Or(s.Workspace, target), Location: s.Location, Retry: retry, Err: err}
	}
}

// folderRequest is how the daemon is asked about a typed folder: ~,
// absolute paths and host: locations as they are (a bare host: is its
// home), anything else under the current folder.
func folderRequest(workspace, typed string) string {
	if host, rest, remote := splitHost(typed); remote {
		if rest != "/" {
			rest = strings.TrimSuffix(rest, "/")
		}
		if rest != "" && rest[0] != '/' && rest[0] != '~' {
			rest = "~/" + rest // as scp reads it: under the remote home
		}
		return host + ":" + cmp.Or(rest, "~")
	}
	if typed != "/" {
		typed = strings.TrimSuffix(typed, "/")
	}
	if strings.HasPrefix(typed, "/") || typed == "~" || strings.HasPrefix(typed, "~/") {
		return typed
	}
	return joinPlace(workspace, typed)
}

type queryKind int

const (
	// queryRecent filters the recent folders, and offers hosts the text
	// starts.
	queryRecent queryKind = iota
	// queryHosts completes a [user@]host before its colon.
	queryHosts
	// queryListing lists a folder, here or on a host.
	queryListing
)

// folderQuery is what the typed text asks the picker for.
type folderQuery struct {
	// dir is the folder to list, as typed.
	dir string
	// segment filters the list: the text after dir's last slash, or all of
	// it outside a listing.
	segment string
	kind    queryKind
}

// parseQuery reads typed text: a path lists its folder filtered by the
// last segment, scp-style host:path lists that folder on the host (host:
// and host:name list its home), and a word without / or : filters the
// recent folders, unless it holds an @ and so can only be user@host.
func parseQuery(q string) folderQuery {
	if q == "~" {
		return folderQuery{kind: queryListing, dir: "~"}
	}
	if host, rest, remote := splitHost(q); remote {
		dir, segment := host+":~", rest
		if rest == "~" {
			segment = ""
		}
		if i := strings.LastIndex(rest, "/"); i >= 0 {
			dir, segment = host+":"+rest[:i+1], rest[i+1:]
		}
		return folderQuery{kind: queryListing, dir: dir, segment: segment}
	}
	if i := strings.LastIndex(q, "/"); i >= 0 {
		return folderQuery{kind: queryListing, dir: q[:i+1], segment: q[i+1:]}
	}
	if strings.Contains(q, "@") {
		return folderQuery{kind: queryHosts, segment: q}
	}
	return folderQuery{kind: queryRecent, segment: q}
}

// bareHost is a [user@]host without its user.
func bareHost(h string) string {
	return h[strings.LastIndex(h, "@")+1:]
}

// hostRows are the hosts the text completes. A word only offers hosts it
// starts, after the folders it matches, so a local filter reads as it
// always did; with an @ every known host matches what follows it, and the
// typed user goes with the completion.
func hostRows(kind queryKind, text string, known []daemon.KnownHost) []folderRow {
	user, name := "", text
	if i := strings.LastIndex(text, "@"); kind == queryHosts && i >= 0 {
		user, name = text[:i+1], text[i+1:]
	}
	names := make([]string, len(known))
	for i, h := range known {
		names[i] = bareHost(h.Host)
	}
	var matches []fuzzy.Match
	switch {
	case kind == queryHosts:
		matches = fuzzyNames(name, names)
	case name != "":
		for i, n := range names {
			if strings.HasPrefix(strings.ToLower(n), strings.ToLower(name)) || strings.HasPrefix(strings.ToLower(known[i].Label), strings.ToLower(name)) {
				matches = append(matches, fuzzy.Match{Str: n, Index: i})
			}
		}
	}
	var rows []folderRow
	for _, match := range matches {
		h := known[match.Index]
		target, label := h.Host, cmp.Or(h.Label, h.Host)
		if user != "@" && user != "" {
			target = user + bareHost(h.Host)
			label = target
		}
		row := folderRow{path: label + ":", name: label, host: label, hostKey: target, source: h.Source, hostRow: true}
		if shift := len(label) - len(match.Str); strings.HasSuffix(label, match.Str) {
			for _, i := range match.MatchedIndexes {
				row.matched = append(row.matched, i+shift)
			}
		}
		rows = append(rows, row)
	}
	return rows
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
	last       *int64
	path, host string
	score      float64
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
			out = append(out, recentFolder{path: s.Workspace, host: sessionHost(s)})
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
	src      folderSource
	asked    map[string]bool
	retry    *WorkspaceRetry
	previews map[string]*cachedFolderPreview
	repos    map[string]*daemon.Repo
	listings map[string]*folderListMsg

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
		sessionsGeneration: time.Now().UnixNano(),
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
	return tea.Batch(m.loadSessionsCmd(), m.loadHostsCmd(), m.fetch(), m.previewCmd())
}

func (m FolderPicker) loadHostsCmd() tea.Cmd {
	src := m.src
	return func() tea.Msg {
		hosts, err := src.Hosts()
		return hostsMsg{Hosts: hosts, Err: err}
	}
}

func (m FolderPicker) loadSessionsCmd() tea.Cmd {
	src, gen := m.src, m.sessionsGeneration
	return func() tea.Msg {
		sessions, err := src.Sessions()
		return folderSessionsMsg{Sessions: sessions, Err: err, Gen: gen}
	}
}

func (m FolderPicker) workspace() string { return m.session.Workspace }

// homed shortens p under its home to start with ~, led by its host's
// label when it is remote.
func (m FolderPicker) homed(p string) string {
	host, _ := daemon.SplitLocation(p)
	return placeText(p, m.labelOf(host), m.homes[m.canonical(host)])
}

// canonical is the [user@]host a typed host turned out to be, or the one
// that reads as it.
func (m FolderPicker) canonical(host string) string {
	if c, ok := m.aliases[host]; ok {
		return c
	}
	for c, label := range m.labels {
		if label == host {
			return c
		}
	}
	return host
}

func (m FolderPicker) labelOf(host string) string {
	return cmp.Or(m.labels[m.canonical(host)], m.labels[host], host)
}

// known are the hosts to complete: the daemon's recent ones, then hosts of
// the sessions here in case the daemon has no list, then its ssh config.
func (m FolderPicker) known() []daemon.KnownHost {
	seen := map[string]bool{}
	var out []daemon.KnownHost
	add := func(h daemon.KnownHost) {
		if h.Host != "" && !seen[h.Host] {
			seen[h.Host] = true
			out = append(out, h)
		}
	}
	for _, h := range m.hosts {
		if h.Source != "config" {
			add(h)
		}
	}
	for _, f := range recentFolders(m.sessions, "", time.Now()) {
		if host, _ := daemon.SplitLocation(f.path); host != "" {
			add(daemon.KnownHost{Host: host, Label: f.host, Source: "recent"})
		}
	}
	for _, h := range m.hosts {
		add(h)
	}
	return out
}

// probe is what is known of a host's reachability: its warm-up, else the
// state the daemon's host list cached. Local folders have none.
func (m FolderPicker) probe(host string) daemon.HostStatus {
	if host == "" {
		return daemon.HostStatus{}
	}
	if p, ok := m.probes[host]; ok {
		return p
	}
	if p, ok := m.probes[m.canonical(host)]; ok {
		return p
	}
	if i := slices.IndexFunc(m.hosts, func(h daemon.KnownHost) bool { return h.Host == m.canonical(host) }); i >= 0 {
		return daemon.HostStatus{Host: host, State: m.hosts[i].State}
	}
	return daemon.HostStatus{}
}

// reachable says a row's folder can be asked about now: it is local, or
// its host answered ready.
func (m FolderPicker) reachable(row folderRow) bool {
	return row.hostKey == "" || m.probe(row.hostKey).State == "ready"
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
	q := parseQuery(m.input.Value())
	segment, listing := q.segment, q.kind == queryListing
	m.rows, m.listed = nil, ""
	var candidates []folderRow
	switch q.kind {
	case queryHosts:
		m.section = "hosts"
	case queryRecent:
		m.section = "recent"
		for _, f := range recentFolders(m.sessions, m.workspace(), time.Now()) {
			host, p := daemon.SplitLocation(f.path)
			candidates = append(candidates, folderRow{path: f.path, host: f.host, hostKey: host, name: path.Base(p), recent: true, age: f.last, repo: true})
		}
	case queryListing:
		m.listed = folderRequest(m.workspace(), q.dir)
		m.section = "in " + m.homed(m.listed)
		if l, ok := m.listing(); ok {
			m.section = "in " + m.homed(l.Path)
			host, _ := daemon.SplitLocation(l.Path)
			for _, e := range l.Entries {
				if e.Hidden && !strings.HasPrefix(segment, ".") {
					continue
				}
				row := folderRow{path: joinPlace(l.Path, e.Name), name: e.Name, hostKey: host, host: m.labelOf(host), repo: e.VCS != ""}
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
	if q.kind != queryListing {
		m.rows = append(m.rows, hostRows(q.kind, segment, m.known())...)
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
		if m.probe(msg.Host).State != "warming" {
			return m, nil
		}
		src, h := m.src, msg.Host
		return m, func() tea.Msg {
			status, err := src.Host(h)
			return hostStatusMsg{Host: h, Status: status, Err: err}
		}
	case hostStatusMsg:
		return m, m.probed(msg)
	case hostSignedInMsg:
		if msg.Err != nil {
			m.notice = "Signing in to " + m.labelOf(msg.Host) + " failed: " + msg.Err.Error()
			return m, nil
		}
		m.warmed[msg.Host], m.warmed[m.canonical(msg.Host)] = false, false
		return m, m.warm(msg.Host)
	case folderListMsg:
		m.listings[msg.Path] = &msg
		if msg.Err == nil {
			m.learnHome(msg.Path, msg.List)
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

// learnHome records the home a listing reported for its host, and which
// host a typed one turned out to be.
func (m *FolderPicker) learnHome(asked string, l daemon.FolderList) {
	if l.Home == "" {
		return
	}
	host, home := daemon.SplitLocation(l.Home)
	m.homes[host] = home
	typed, _, remote := splitHost(asked)
	canonical, _ := daemon.SplitLocation(l.Path)
	if !remote || canonical == "" || typed == canonical {
		return
	}
	m.aliases[typed] = canonical
	if m.labels[canonical] == "" {
		m.labels[canonical] = typed
	}
	if p, ok := m.probes[typed]; ok && m.probes[canonical].State == "" {
		m.probes[canonical], m.warmed[canonical] = p, true
	}
}

// hostPollEvery is how often a warming host is asked again.
const hostPollEvery = 750 * time.Millisecond

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
	src := m.src
	return tea.Batch(func() tea.Msg {
		status, err := src.Warm(host)
		return hostStatusMsg{Host: host, Status: status, Err: err, Warmed: true}
	}, pollHost(host))
}

func pollHost(host string) tea.Cmd {
	return tea.Tick(hostPollEvery, func(time.Time) tea.Msg { return hostPollMsg{Host: host} })
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
		return pollHost(msg.Host)
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
	return tea.ExecProcess(signInCommand(host, probe.ControlPath), func(err error) tea.Msg {
		return hostSignedInMsg{Host: host, Err: err}
	})
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
	return m, tea.Batch(cmd, m.follow())
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
	// a remote ~ is only known once its listing answers
	if host, rest, remote := splitHost(dir); remote && !strings.HasPrefix(rest, "/") {
		if rest == "~" {
			return m.input.Value()
		}
		return host + ":" + path.Dir(rest) + "/"
	}
	up := m.homed(parentPlace(dir))
	if strings.HasSuffix(up, "/") {
		return up
	}
	return up + "/"
}

// target is the folder enter moves to: the highlighted row, or the typed
// folder itself when it has nothing left to pick.
func (m FolderPicker) target() string {
	if row, ok := m.highlighted(); ok {
		return row.path
	}
	if q := parseQuery(m.input.Value()); q.kind == queryListing && q.segment == "" {
		if l, ok := m.listing(); ok {
			return l.Path
		}
	}
	return ""
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
		if !row.repo || m.asked["repo:"+row.path] || !m.reachable(row) {
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
	if !ok || row.hostRow || m.previews[row.path] != nil || !m.reachable(row) {
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
