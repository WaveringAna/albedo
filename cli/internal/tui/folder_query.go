package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"path"
	"slices"
	"strings"
	"time"

	"github.com/sahilm/fuzzy"
)

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
		return host + ":" + scpRelative(path.Dir(rest)) + "/"
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
