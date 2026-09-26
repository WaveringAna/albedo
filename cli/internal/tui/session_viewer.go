package tui

import (
	"albedo/cli/internal/daemon"
	"slices"
	"sort"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func sessionText(s string) string { return daemon.SessionText(ansi.Strip(s)) }

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

// PreviewItem is one transcript excerpt from GET /sessions/{id}/preview.
type PreviewItem struct {
	Type    string `json:"type"`
	Preview string `json:"preview"`
}

type SessionPreview struct {
	Items []PreviewItem `json:"items"`
	Total int           `json:"total"`
}

// SessionPreviewMsg carries a fetched preview back to the viewer.
type SessionPreviewMsg struct {
	ID      string
	Preview SessionPreview
	Err     error
}

type sessionPreviewTickMsg struct{ ID string }

type cachedPreview struct {
	SessionPreview
	stamp   int64 // LastAssistantAt when fetched; a newer reply invalidates it
	loading bool
	err     bool
}

// SessionViewer is the start screen: search over a grouped session list
// beside a transcript preview of the highlighted session.
type SessionViewer struct {
	PickerModel
	Sessions      []daemon.Session
	Workspace     string
	Loading       bool
	HasActive     bool
	ArchiveView   bool
	ConfirmDelete string

	// PrefsPath stores picker and chat preferences; empty keeps them in memory only.
	PrefsPath string
	// Fetch loads a preview; nil disables previews.
	Fetch func(id string) tea.Cmd

	prefs    sessionPrefs
	raw      []daemon.Session
	active   *daemon.Session
	section  map[string]int
	previews map[string]*cachedPreview
	notice   string
	now      func() time.Time
}

func NewSessionViewer(workspace string) SessionViewer {
	p := NewPickerModel("", sessionViewerActions(workspace), true, "new")
	p.SearchInput.Placeholder = "search sessions, models, folders…"
	st := p.SearchInput.Styles()
	st.Focused.Placeholder = DefaultStyles.Faint
	st.Blurred.Placeholder = DefaultStyles.Faint
	p.SearchInput.SetStyles(st)
	return SessionViewer{
		PickerModel: p,
		Workspace:   workspace,
		Loading:     true,
		section:     map[string]int{},
		previews:    map[string]*cachedPreview{},
		now:         time.Now,
	}
}

func sessionViewerActions(workspace string) []PickerItem {
	return []PickerItem{
		{ID: "new", Label: "New session", Detail: workspace},
		{ID: "login", Label: "Accounts", Detail: "add or select a provider"},
		{ID: "archive", Label: "Archive", Detail: "browse archived sessions"},
	}
}

// LoadPrefs reads picker and chat preferences from path.
func (m *SessionViewer) LoadPrefs(path string) {
	m.PrefsPath = path
	m.prefs = loadSessionPrefs(path)
	m.rebuild()
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
	m.raw = sessions
	m.active = active
	previous, ok := m.Highlighted()
	m.rebuild()
	// Initial load favors the active or most recent session; later refreshes
	// keep the cursor.
	target := ""
	if active != nil && !m.prefs.archived(active.ID) && !m.ArchiveView {
		target = active.ID
	} else if ok && m.section[previous.ID] != secAction {
		target = previous.ID
	} else {
		for _, s := range m.Sessions {
			if m.section[s.ID] >= secToday {
				target = s.ID
				break
			}
		}
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
	if m.prefs.forget(known) {
		m.savePrefs()
	}
}

// rebuild orders sessions into sections and refreshes the picker items,
// keeping the search and the highlighted item.
func (m *SessionViewer) rebuild() {
	if m.section == nil {
		m.section = map[string]int{}
	}
	listed := m.raw
	if m.active != nil && !containsSession(listed, m.active.ID) {
		listed = append([]daemon.Session{*m.active}, listed...)
	}
	now := m.clock()
	byID := make(map[string]daemon.Session, len(listed))
	for _, s := range listed {
		byID[s.ID] = s
	}
	clear(m.section)
	var ordered []daemon.Session
	for _, id := range m.prefs.Pinned {
		if s, ok := byID[id]; ok && !m.prefs.archived(id) {
			m.section[id] = secPinned
			ordered = append(ordered, s)
		}
	}
	var frequent []daemon.Session
	for _, s := range listed {
		if _, taken := m.section[s.ID]; !taken && !m.prefs.archived(s.ID) && m.prefs.Opens[s.ID] >= frequentMinOpens {
			frequent = append(frequent, s)
		}
	}
	sort.SliceStable(frequent, func(i, j int) bool {
		return m.prefs.Opens[frequent[i].ID] > m.prefs.Opens[frequent[j].ID]
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
	var rest []daemon.Session
	for i, s := range listed {
		if m.prefs.archived(s.ID) {
			m.section[s.ID] = secArchived
			continue
		}
		if _, taken := m.section[s.ID]; taken {
			continue
		}
		m.section[s.ID] = dated[i]
		if m.active != nil && s.ID == m.active.ID {
			m.section[s.ID] = secToday
			rest = append([]daemon.Session{s}, rest...)
			continue
		}
		rest = append(rest, s)
	}
	// Navigation follows the grouping; the daemon's order holds within a day group.
	sort.SliceStable(rest, func(i, j int) bool { return m.section[rest[i].ID] < m.section[rest[j].ID] })
	m.Sessions = append(ordered, rest...)

	items := sessionViewerActions(m.Workspace)
	if m.ArchiveView {
		items = nil
	}
	visible := m.Sessions
	if m.ArchiveView {
		visible = listed
	}
	for _, s := range visible {
		if m.ArchiveView != m.prefs.archived(s.ID) {
			continue
		}
		items = append(items, PickerItem{ID: s.ID, Label: sessionTitle(s), Detail: sessionText(s.Workspace + " " + s.Model + " " + s.Provider)})
	}
	m.Items = items
	m.applyFilter()
}

func sessionTitle(s daemon.Session) string {
	title := strings.TrimSpace(sessionText(s.Title))
	if title == "" || title == "new session" {
		return "Untitled session"
	}
	return title
}

func containsSession(sessions []daemon.Session, id string) bool {
	for _, s := range sessions {
		if s.ID == id {
			return true
		}
	}
	return false
}

func (m *SessionViewer) focus(id string) {
	for i, item := range m.Filtered {
		if item.ID == id {
			m.Cursor = i
			return
		}
	}
}

func (m SessionViewer) session(id string) (daemon.Session, bool) {
	for _, s := range m.raw {
		if s.ID == id {
			return s, true
		}
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

// RecordOpen counts an open for the most-used group.
func (m *SessionViewer) RecordOpen(id string) {
	if _, ok := m.session(id); !ok {
		return
	}
	m.prefs.recordOpen(id)
	m.savePrefs()
}

func (m *SessionViewer) togglePin() {
	item, ok := m.Highlighted()
	if !ok || m.section[item.ID] == secAction || m.ArchiveView {
		return
	}
	m.prefs.togglePin(item.ID)
	m.savePrefs()
	m.rebuild()
	m.focus(item.ID)
}

func (m *SessionViewer) savePrefs() {
	m.notice = ""
	if err := m.prefs.save(m.PrefsPath); err != nil {
		m.notice = "could not save session preferences: " + err.Error()
	}
}

type SessionDeleteMsg struct{ ID string }

func (m *SessionViewer) toggleArchive() {
	item, ok := m.Highlighted()
	if !ok || m.section[item.ID] == secAction {
		return
	}
	if m.prefs.archived(item.ID) {
		m.prefs.Archived = slices.DeleteFunc(m.prefs.Archived, func(id string) bool { return id == item.ID })
	} else {
		m.prefs.Archived = append(m.prefs.Archived, item.ID)
	}
	index := m.Cursor
	m.savePrefs()
	m.rebuild()
	m.Cursor = min(index, max(0, len(m.Filtered)-1))
}

func (m *SessionViewer) OpenArchive() {
	m.ArchiveView = true
	m.ConfirmDelete = ""
	m.SearchInput.SetValue("")
	m.rebuild()
	m.Cursor = 0
}

func (m *SessionViewer) CloseArchive() {
	m.ArchiveView = false
	m.ConfirmDelete = ""
	m.SearchInput.SetValue("")
	m.rebuild()
	m.focus("archive")
}

func (m *SessionViewer) Removed(id string) {
	m.raw = slices.DeleteFunc(m.raw, func(s daemon.Session) bool { return s.ID == id })
	m.prefs.Archived = slices.DeleteFunc(m.prefs.Archived, func(v string) bool { return v == id })
	m.prefs.Pinned = slices.DeleteFunc(m.prefs.Pinned, func(v string) bool { return v == id })
	delete(m.prefs.Opens, id)
	delete(m.previews, id)
	m.ConfirmDelete = ""
	m.savePrefs()
	m.rebuild()
}

func (m SessionViewer) Update(msg tea.Msg) (SessionViewer, tea.Cmd) {
	before, _ := m.Highlighted()
	switch msg := msg.(type) {
	case SessionPreviewMsg:
		if c := m.previews[msg.ID]; c != nil {
			c.loading = false
			c.err = msg.Err != nil
			if msg.Err == nil {
				c.SessionPreview = msg.Preview
			}
		}
		return m, nil
	case sessionPreviewTickMsg:
		if item, ok := m.Highlighted(); ok && item.ID == msg.ID {
			return m, m.fetchPreview(msg.ID)
		}
		return m, nil
	case tea.KeyPressMsg:
		if m.ConfirmDelete != "" {
			id := m.ConfirmDelete
			m.ConfirmDelete = ""
			if msg.Text == "y" {
				return m, func() tea.Msg { return SessionDeleteMsg{ID: id} }
			}
			return m, nil
		}
		if m.ArchiveView && msg.String() == "esc" {
			m.CloseArchive()
			return m, nil
		}
		switch msg.String() {
		case "ctrl+d":
			if m.ArchiveView {
				if item, ok := m.Highlighted(); ok {
					m.ConfirmDelete = item.ID
				}
			}
			return m, nil
		case "ctrl+a":
			m.toggleArchive()
			return m, nil
		case "ctrl+s":
			m.togglePin()
			return m, nil
		case "tab", "shift+tab":
			m.switchGroup()
			return m, m.previewAfter(before.ID)
		case "left", "right":
			// Arrows edit the query once there is one.
			if m.SearchInput.Value() == "" {
				m.switchGroup()
				return m, m.previewAfter(before.ID)
			}
		}
	}
	picker, cmd := m.PickerModel.Update(msg)
	m.PickerModel = picker
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
