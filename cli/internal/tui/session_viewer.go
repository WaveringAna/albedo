package tui

import (
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/presentation"
	"cmp"
	"slices"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func sessionText(s string) string { return presentation.SessionText(ansi.Strip(s)) }

// Sections of the session list, in navigation order. Pinned and most used
// sessions lead the dated groups.
const (
	secAction = iota
	secPinned
	secFrequent
	secToday
	secWeek
	secEarlier
	secArchived
)

var sectionTitles = [...]string{"", "pinned", "most used", "today", "this week", "earlier", "archived"}

// frequentLimit caps the most-used group; a session needs frequentMinOpens
// opens before it counts as used rather than merely visited.
const (
	frequentLimit    = 5
	frequentMinOpens = 2
	previewDebounce  = 120 * time.Millisecond
)

// SessionPreviewMsg carries a fetched preview back to the viewer.
type SessionPreviewMsg struct {
	Err     error
	ID      string
	Preview daemon.SessionPreview
}

type sessionPreviewTickMsg struct{ ID string }

type cachedPreview struct {
	daemon.SessionPreview
	stamp   int64 // LastAssistantAt when fetched; a newer reply invalidates it
	loading bool
	err     bool
}

type sessionGroup struct {
	section int
	first   int
	count   int
}

// SessionViewer is the start screen: search over a grouped session list
// beside a transcript preview of the highlighted session.
type SessionViewer struct {
	active *daemon.Session
	// Fetch loads a preview; nil disables previews.
	Fetch         func(id string) tea.Cmd
	now           func() time.Time
	previews      map[string]*cachedPreview
	section       map[string]int
	sessionIndex  map[string]int
	archivedIDs   map[string]bool
	Workspace     string
	ConfirmDelete string
	notice        string
	Sessions      []daemon.Session
	raw           []daemon.Session
	groups        []sessionGroup

	prefs  sessionPrefs
	rename renameField
	PickerModel
	sectionCounts [len(sectionTitles)]int
	Loading       bool

	HasActive   bool
	ArchiveView bool
	Saving      bool
}

// workspacePlace is the viewer's folder as text, its host labelled the way
// the daemon labels it on any session there.
func (m SessionViewer) workspacePlace() string {
	if i := slices.IndexFunc(m.raw, func(s daemon.Session) bool { return s.Workspace == m.Workspace }); i >= 0 {
		return sessionPlace(m.raw[i])
	}
	return placeText(m.Workspace, "", "")
}

func NewSessionViewer(workspace string) SessionViewer {
	p := NewPickerModel("", sessionViewerActions(workspace), true, "new")
	p.SearchInput.Placeholder = "search sessions, models, folders…"
	st := p.SearchInput.Styles()
	st.Focused.Placeholder, st.Blurred.Placeholder = DefaultStyles.Faint, DefaultStyles.Faint
	p.SearchInput.SetStyles(st)
	m := SessionViewer{
		PickerModel: p,
		Workspace:   workspace,
		Loading:     true,
		section:     map[string]int{},
		previews:    map[string]*cachedPreview{},
		now:         time.Now,
	}
	m.rebuildGroups()
	return m
}

func sessionViewerActions(workspace string) []PickerItem {
	return []PickerItem{
		{ID: "new", Label: "New session", Detail: workspace},
		{ID: "login", Label: "Accounts", Detail: "add or select a provider"},
		{ID: "archive", Label: "Archive", Detail: "browse archived sessions"},
	}
}

func (m *SessionViewer) SetSize(width, height int) {
	m.PickerModel.SetSize(width, height)
	m.SearchInput.SetWidth(max(1, width-8))
}

func (m SessionViewer) clock() time.Time {
	if m.now == nil {
		return time.Now()
	}
	return m.now()
}

func dateSection(s daemon.Session, now time.Time) int {
	if s.LastAssistantAt == nil {
		return secEarlier
	}
	t := time.Unix(*s.LastAssistantAt, 0)
	y, mo, d := now.Date()
	midnight := time.Date(y, mo, d, 0, 0, 0, 0, now.Location())
	switch {
	case !t.Before(midnight):
		return secToday
	case !t.Before(midnight.AddDate(0, 0, -6)):
		return secWeek
	}
	return secEarlier
}

func (m *SessionViewer) SetSessions(sessions []daemon.Session, active *daemon.Session) {
	m.Loading = false
	m.HasActive = active != nil
	m.raw = slices.Clone(sessions)
	m.active = active
	previous, ok := m.Highlighted()
	m.rebuild()
	// Initial load favors the active or most recent session; later refreshes
	// keep the cursor.
	target := ""
	if active != nil && !m.archivedIDs[active.ID] && !m.ArchiveView {
		target = active.ID
	} else if ok && m.section[previous.ID] != secAction {
		target = previous.ID
	} else if i := slices.IndexFunc(m.Sessions, func(s daemon.Session) bool { return m.section[s.ID] >= secToday }); i >= 0 {
		target = m.Sessions[i].ID
	}
	m.focus(target)
}

// Prune forgets pins and counts for sessions the daemon no longer has. Call it
// only with a complete, successfully loaded session list.
func (m *SessionViewer) Prune(sessions []daemon.Session) {
	known := make(map[string]bool, len(sessions))
	for _, s := range sessions {
		known[s.ID] = true
	}
	m.prefs.forget(known)
}

// rebuild orders sessions into sections and refreshes the picker items,
// keeping the search and the highlighted item.
func (m *SessionViewer) rebuild() {
	highlighted, ok := m.Highlighted()
	slot := m.Cursor
	if m.section == nil {
		m.section = map[string]int{}
	}
	// Session indexes refer to the daemon listing in raw.
	m.sessionIndex = make(map[string]int, len(m.raw))
	for i, session := range m.raw {
		if _, exists := m.sessionIndex[session.ID]; !exists {
			m.sessionIndex[session.ID] = i
		}
	}
	m.archivedIDs = make(map[string]bool, len(m.prefs.Archived))
	for _, id := range m.prefs.Archived {
		m.archivedIDs[id] = true
	}
	listed := m.raw
	if m.active != nil {
		if _, exists := m.sessionIndex[m.active.ID]; !exists {
			listed = append([]daemon.Session{*m.active}, listed...)
		}
	}
	now := m.clock()
	clear(m.section)
	var ordered []daemon.Session
	for _, id := range m.prefs.Pinned {
		if s, ok := m.session(id); ok && !m.archivedIDs[id] {
			m.section[id] = secPinned
			ordered = append(ordered, s)
		}
	}
	var frequent []daemon.Session
	for _, s := range listed {
		if _, taken := m.section[s.ID]; !taken && !m.archivedIDs[s.ID] && m.prefs.Opens[s.ID] >= frequentMinOpens {
			frequent = append(frequent, s)
		}
	}
	slices.SortStableFunc(frequent, func(a, b daemon.Session) int {
		return cmp.Compare(m.prefs.Opens[b.ID], m.prefs.Opens[a.ID])
	})
	for _, s := range frequent[:min(len(frequent), frequentLimit)] {
		m.section[s.ID] = secFrequent
		ordered = append(ordered, s)
	}
	// A session with no reply yet has no date of its own. The daemon lists by
	// activity, so it takes the group of the next older dated session; the
	// session in use is always today's and leads the list.
	dated := make([]int, len(listed))
	older := secEarlier
	for i := len(listed) - 1; i >= 0; i-- {
		if listed[i].LastAssistantAt != nil {
			older = dateSection(listed[i], now)
		}
		dated[i] = older
	}
	var rest, active []daemon.Session
	for i, s := range listed {
		if m.archivedIDs[s.ID] {
			m.section[s.ID] = secArchived
			continue
		}
		if _, taken := m.section[s.ID]; taken {
			continue
		}
		m.section[s.ID] = dated[i]
		if m.active != nil && s.ID == m.active.ID {
			m.section[s.ID] = secToday
			active = []daemon.Session{s}
			continue
		}
		rest = append(rest, s)
	}
	// Navigation follows the grouping; the daemon's order holds within a day group.
	slices.SortStableFunc(rest, func(a, b daemon.Session) int { return cmp.Compare(m.section[a.ID], m.section[b.ID]) })
	m.Sessions = slices.Concat(ordered, active, rest)

	var items []PickerItem
	visible := m.Sessions
	if m.ArchiveView {
		visible = listed
	} else {
		items = sessionViewerActions(m.Workspace)
	}
	for _, s := range visible {
		if m.ArchiveView == m.archivedIDs[s.ID] {
			items = append(items, PickerItem{ID: s.ID, Label: sessionTitle(s), Detail: sessionText(s.Workspace + " " + s.Model + " " + s.Provider)})
		}
	}
	m.Items = items
	m.applyFilter()
	// A session that left the list (archived, restored, deleted) leaves its
	// slot to the next one rather than sending the cursor to the top.
	if gone := ok && !slices.ContainsFunc(m.Filtered, func(item PickerItem) bool { return item.ID == highlighted.ID }); gone {
		m.Cursor = max(0, min(slot, len(m.Filtered)-1))
	}
	m.rebuildGroups()
}

// Group ranges index Filtered, so cursor movement and resizing can derive
// physical rows without rebuilding or formatting the rest of the list.
func (m *SessionViewer) rebuildGroups() {
	m.groups = nil
	clear(m.sectionCounts[:])
	for i, item := range m.Filtered {
		section := m.section[item.ID]
		m.sectionCounts[section]++
		if len(m.groups) == 0 || m.groups[len(m.groups)-1].section != section {
			m.groups = append(m.groups, sessionGroup{section: section, first: i})
		}
		m.groups[len(m.groups)-1].count++
	}
}

const untitled = "Untitled session"

func sessionTitle(s daemon.Session) string {
	title := strings.TrimSpace(sessionText(s.Title))
	if title == "" || title == "new session" {
		return untitled
	}
	return title
}

func (m *SessionViewer) focus(id string) {
	if i := slices.IndexFunc(m.Filtered, func(item PickerItem) bool { return item.ID == id }); i >= 0 {
		m.Cursor = i
	}
}

func (m SessionViewer) session(id string) (daemon.Session, bool) {
	if index, ok := m.sessionIndex[id]; ok {
		return m.raw[index], true
	}
	if m.active != nil && m.active.ID == id {
		return *m.active, true
	}
	return daemon.Session{}, false
}

// favourite reports whether a Filtered index belongs to the leading groups
// (actions, pins, most used) rather than the dated groups.
func (m SessionViewer) favourite(i int) bool {
	return i >= 0 && i < len(m.Filtered) && m.section[m.Filtered[i].ID] <= secFrequent
}

// switchGroup jumps between the leading and dated groups.
func (m *SessionViewer) switchGroup() {
	toFavourites := !m.favourite(m.Cursor)
	first := -1
	for i := range m.Filtered {
		if m.favourite(i) != toFavourites {
			continue
		}
		if first < 0 {
			first = i
		}
		// Prefer a pinned or frequent session over the actions.
		if !toFavourites || m.section[m.Filtered[i].ID] != secAction {
			m.Cursor = i
			return
		}
	}
	if first >= 0 {
		m.Cursor = first
	}
}

// SessionPreferenceMsg requests a single explicit change; the root model owns I/O.
type SessionPreferenceMsg struct {
	ID, Field, ETag string
	Value           bool
}

func (m *SessionViewer) togglePin() tea.Cmd {
	item, ok := m.Highlighted()
	if !ok || m.section[item.ID] == secAction || m.ArchiveView || m.Saving {
		return nil
	}
	value := !m.prefs.pinned(item.ID)
	session, _ := m.session(item.ID)
	m.Saving = true
	return func() tea.Msg {
		return SessionPreferenceMsg{ID: item.ID, Field: "pinned", Value: value, ETag: session.ETag}
	}
}

type SessionDeleteMsg struct {
	ID        string
	Condition daemon.SessionCondition
}

// SessionFoldersMsg browses sessions by folder, starting from Query.
type SessionFoldersMsg struct{ Query string }

// startRename opens the highlighted session's name for editing, starting
// from the title it shows now.
func (m *SessionViewer) startRename() {
	item, ok := m.Highlighted()
	s, isSession := m.session(item.ID)
	if !ok || !isSession {
		return
	}
	current := sessionTitle(s)
	if current == untitled {
		current = ""
	}
	if s.ETag == "" {
		m.notice = "Wait for the session preview, then rename."
		return
	}
	m.rename.open(s.ID, current, "Name this session")
	m.rename.etag = s.ETag
}

// Renamed takes a session's new listing from the daemon.
func (m *SessionViewer) Renamed(s daemon.Session) {
	for i := range m.raw {
		if m.raw[i].ID == s.ID {
			m.raw[i] = s
		}
	}
	if m.active != nil && m.active.ID == s.ID {
		m.active = &s
	}
	item, _ := m.Highlighted()
	m.rebuild()
	m.focus(item.ID)
}

func (m *SessionViewer) toggleArchive() tea.Cmd {
	item, ok := m.Highlighted()
	if !ok || m.section[item.ID] == secAction || m.Saving {
		return nil
	}
	value := !m.archivedIDs[item.ID]
	session, _ := m.session(item.ID)
	m.Saving = true
	return func() tea.Msg {
		return SessionPreferenceMsg{ID: item.ID, Field: "archived", Value: value, ETag: session.ETag}
	}
}

func (m *SessionViewer) OpenArchive() { m.setArchive(true) }

func (m *SessionViewer) CloseArchive() { m.setArchive(false) }

// setArchive enters or leaves the archive view, which always drops the
// delete confirmation and the search.
func (m *SessionViewer) setArchive(open bool) {
	m.ArchiveView = open
	m.ConfirmDelete = ""
	m.SearchInput.SetValue("")
	m.rebuild()
	m.Cursor = 0
	if !open {
		m.focus("archive")
	}
}

func (m *SessionViewer) Removed(id string) {
	m.raw = slices.DeleteFunc(m.raw, func(s daemon.Session) bool { return s.ID == id })
	m.prefs.Archived = slices.DeleteFunc(m.prefs.Archived, func(v string) bool { return v == id })
	m.prefs.Pinned = slices.DeleteFunc(m.prefs.Pinned, func(v string) bool { return v == id })
	delete(m.prefs.Opens, id)
	delete(m.previews, id)
	m.ConfirmDelete = ""
	m.rebuild()
}

func (m SessionViewer) Update(msg tea.Msg) (SessionViewer, tea.Cmd) {
	before, _ := m.Highlighted()
	switch msg := msg.(type) {
	case SessionPreviewMsg:
		if c := m.previews[msg.ID]; c != nil {
			c.loading, c.err = false, msg.Err != nil
			if !c.err {
				c.SessionPreview = msg.Preview
				if msg.Preview.Session != nil {
					for i := range m.raw {
						if m.raw[i].ID == msg.ID {
							m.raw[i] = *msg.Preview.Session
						}
					}
				}
			}
		}
		return m, nil
	case sessionPreviewTickMsg:
		if item, ok := m.Highlighted(); ok && item.ID == msg.ID {
			return m, m.fetchPreview(msg.ID)
		}
		return m, nil
	case tea.KeyPressMsg:
		if m.rename.active() {
			return m, m.rename.key(msg)
		}
		if m.ConfirmDelete != "" {
			id := m.ConfirmDelete
			m.ConfirmDelete = ""
			if msg.Text == "y" {
				s, _ := m.session(id)
				return m, func() tea.Msg {
					return SessionDeleteMsg{ID: id, Condition: daemon.SessionCondition{ETag: s.ETag, FamilyRevision: s.FamilyRevision}}
				}
			}
			return m, nil
		}
		if m.ArchiveView && msg.String() == "esc" {
			m.CloseArchive()
			return m, nil
		}
		switch key := msg.String(); {
		case key == "ctrl+d":
			if item, ok := m.Highlighted(); m.ArchiveView && ok {
				s, _ := m.session(item.ID)
				if s.ETag == "" {
					m.notice = "Wait for the session preview, then delete."
				} else {
					m.ConfirmDelete = item.ID
				}
			}
			return m, nil
		case key == "ctrl+a":
			cmd := m.toggleArchive()
			return m, cmd
		case key == "ctrl+s":
			cmd := m.togglePin()
			return m, cmd
		case key == "ctrl+r":
			m.startRename()
			return m, nil
		case !m.ArchiveView && (key == "ctrl+f" || (m.SearchInput.Value() == "" && (msg.Text == "~" || msg.Text == "/"))):
			// A path typed into an empty search means a folder.
			query := msg.Text
			return m, func() tea.Msg { return SessionFoldersMsg{Query: query} }
		case key == "tab" || key == "shift+tab" || ((key == "left" || key == "right") && m.SearchInput.Value() == ""):
			m.switchGroup()
			return m, m.previewAfter(before.ID)
		}
	}
	query := m.SearchInput.Value()
	picker, cmd := m.PickerModel.Update(msg)
	m.PickerModel = picker
	if m.SearchInput.Value() != query {
		m.rebuildGroups()
	}
	return m, tea.Batch(cmd, m.previewAfter(before.ID))
}

// previewAfter schedules a preview once the highlight moves to a new row.
func (m SessionViewer) previewAfter(before string) tea.Cmd {
	if item, ok := m.Highlighted(); !ok || item.ID == before {
		return nil
	}
	return m.PreviewCmd()
}

// PreviewCmd requests the highlighted session's preview after a short pause,
// so scrolling through the list does not fire a request per row.
func (m SessionViewer) PreviewCmd() tea.Cmd {
	item, ok := m.Highlighted()
	if !ok || m.Fetch == nil || m.fresh(item.ID) {
		return nil
	}
	id := item.ID
	return tea.Tick(previewDebounce, func(time.Time) tea.Msg { return sessionPreviewTickMsg{ID: id} })
}

func (m SessionViewer) fresh(id string) bool {
	s, ok := m.session(id)
	if !ok {
		return true // actions have no transcript
	}
	c := m.previews[id]
	return c != nil && (c.loading || c.stamp == stampOf(s))
}

func stampOf(s daemon.Session) int64 {
	if s.LastAssistantAt == nil {
		return 0
	}
	return *s.LastAssistantAt
}

func (m *SessionViewer) fetchPreview(id string) tea.Cmd {
	s, ok := m.session(id)
	if !ok || m.Fetch == nil || m.fresh(id) {
		return nil
	}
	if m.previews == nil {
		m.previews = map[string]*cachedPreview{}
	}
	c := m.previews[id]
	if c == nil {
		c = &cachedPreview{}
		m.previews[id] = c
	}
	c.stamp, c.loading = stampOf(s), true
	return m.Fetch(id)
}
