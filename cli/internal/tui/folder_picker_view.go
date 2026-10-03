package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"fmt"
	"math"
	"path"
	"slices"
	"strings"
	"time"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// folderLayout splits the screen below the prompt: the list, and the
// preview beside it when there is room.
type folderLayout struct {
	body, list, pane int
}

func (m FolderPicker) layout() folderLayout {
	width, height := cmp.Or(m.Width, 80), cmp.Or(m.Height, 24)
	l := folderLayout{body: max(1, height-6), list: width}
	if width >= 96 && height >= 14 {
		l.list = width / 2
		l.pane = width - l.list - ansi.StringWidth(svSep())
	}
	return l
}

// visibleRows is the range of rows the list window shows, the way
// scrollWindow cuts it under the section rule.
func (m FolderPicker) visibleRows() (first, last int) {
	h, n := m.layout().body, len(m.rows)+1
	if n <= h {
		return 0, len(m.rows)
	}
	start := min(max(0, m.cursor+1-h/2), n-h)
	return max(0, start-1), min(len(m.rows), start+h-1)
}

func (m FolderPicker) View() string {
	width, height := cmp.Or(m.Width, 80), cmp.Or(m.Height, 24)
	l := m.layout()
	heading, title := "sessions by folder", ""
	if !m.browse {
		heading, title = "move session", DefaultStyles.Faint.Render(sessionTitle(m.session))
	}
	lines := []string{
		" " + titleRule(width-1, brand("albedo")+" "+DefaultStyles.Muted.Render(heading), title), "",
		" " + promptLead() + m.input.View(), "",
	}
	list := m.list(l.list, l.body)
	if l.pane > 0 {
		pane := m.preview(l.pane-1, l.body)
		for i := range list {
			list[i] += svSep() + svFit(pane[i], l.pane-1) + " "
		}
	}
	lines = append(lines, list...)
	lines = append(lines, "", m.footer(width))
	if len(lines) > height {
		lines = append(lines[:max(0, height-1)], lines[len(lines)-1])
	}
	for i, line := range lines {
		lines[i] = ansi.Truncate(line, width, "…")
	}
	return strings.Join(lines, "\n")
}

func (m FolderPicker) footer(width int) string {
	left := " " + keyHints(m.hints()...)
	room := width - ansi.StringWidth(left) - 4
	if room < 24 {
		left = ""
		if m.sessionsError != "" {
			// Keep recovery discoverable when the full navigation help cannot fit.
			action := "retry"
			if m.sessionsLoading {
				action = "retrying…"
			}
			left = ansi.Truncate(" "+keyHints(hint{"ctrl+r", action}), max(0, width-1), "")
		}
		room = max(0, width-ansi.StringWidth(left)-2)
	}
	var right string
	switch {
	case m.moving:
		right = DefaultStyles.Faint.Render("moving…")
	case m.notice != "":
		right = DefaultStyles.Warning.Render(tailFit(m.notice, room))
	case m.deadHighlighted() != "":
		right = DefaultStyles.Error.Render(ansi.Truncate(m.deadHighlighted(), room, "…"))
	case m.sessionsError != "":
		right = DefaultStyles.Warning.Render(ansi.Truncate("Recent sessions: "+m.sessionsError, room, "…"))
	case m.retry != nil:
		right = DefaultStyles.Warning.Render("Folder not found: ") + DefaultStyles.Muted.Render(tailFit(m.homed(m.retry.Missing), room-ansi.StringWidth("Folder not found: ")))
	case m.browse: // nothing moves, so there is no "now in"
	default:
		right = DefaultStyles.Faint.Render("now in ") + DefaultStyles.Muted.Render(tailFit(m.homed(m.workspace()), room-7))
	}
	return left + strings.Repeat(" ", max(1, width-ansi.StringWidth(left)-ansi.StringWidth(right)-1)) + right
}

// hints are the footer's keys for where the cursor is; → shows only when
// the highlighted folder has sessions to step into.
func (m FolderPicker) hints() []hint {
	var hints []hint
	if m.sessionsError != "" {
		action := "retry sessions"
		if m.sessionsLoading {
			action = "retrying…"
		}
		hints = append(hints, hint{"ctrl+r", action})
	}
	if m.inSessions {
		return append(hints, hint{"↑↓", "move"}, hint{"enter", "open"}, hint{"←", "folders"})
	}
	hints = append(hints, hint{"↑↓", "move"}, hint{"tab", "open"}, hint{"⇧tab", "up"})
	row, ok := m.highlighted()
	if ok && len(m.sessionsIn(row.path)) > 0 {
		hints = append(hints, hint{"→", "sessions"})
	}
	if ok && m.probe(row.hostKey).State == "needs_auth" {
		hints = append(hints, hint{"ctrl+l", "sign in"})
	}
	action := "move here"
	if m.browse {
		action = "new session"
	}
	return append(hints, hint{"enter", action}, hint{"esc", "back"})
}

// tailFit keeps the end of plain text, where a path names its folder.
func tailFit(s string, w int) string {
	if n := ansi.StringWidth(s); n > w {
		return "…" + ansi.TruncateLeft(s, n-w+1, "")
	}
	return s
}

// list is the section rule over the rows, at exactly width × height.
func (m FolderPicker) list(width, height int) []string {
	all := []string{sectionRule(m.section, len(m.rows), width)}
	here, latest := m.workspace(), m.latestOther()
	now := time.Now()
	for i, row := range m.rows {
		all = append(all, m.row(row, i == m.cursor, row.path == here, row.path == latest, width, now))
	}
	if len(m.rows) == 0 {
		all = append(all, DefaultStyles.Faint.Render("   "+m.emptyNote()))
	}
	return scrollWindow(all, m.cursor+1, width, height)
}

// typedHost is the host a remote listing is typed for, as a row.
func (m FolderPicker) typedHost() folderRow {
	if host, _, remote := splitHost(m.listed); remote {
		return folderRow{hostKey: m.canonical(host), hostRow: true}
	}
	return folderRow{}
}

// deadHighlighted is why the highlighted row's host cannot be reached, in
// full, or empty when it can.
func (m FolderPicker) deadHighlighted() string {
	row, _ := m.highlighted()
	if row.hostKey == "" {
		row = m.typedHost()
	}
	if p := m.probe(row.hostKey); p.State == "unreachable" || p.State == "unsupported" {
		return m.labelOf(row.hostKey) + ": " + cmp.Or(p.Detail, p.State)
	}
	return ""
}

func (m FolderPicker) emptyNote() string {
	l := m.listings[m.listed]
	host, _, remote := splitHost(m.listed)
	switch {
	case m.listed == "" && m.section == "hosts":
		return "no known hosts match; type host: to browse one"
	case m.listed == "":
		return "no matches"
	case l == nil && remote && m.probe(m.canonical(host)).State == "warming":
		label := m.labelOf(host)
		return reachingText(label, m.probe(m.canonical(host)).Step) + " " + DefaultStyles.Agent.Render(connectingFace(label, m.frame))
	case l == nil:
		return "loading…"
	case l.Err != nil:
		return l.Err.Error()
	case len(l.List.Entries) == 0:
		return "No folders here"
	}
	return "no matches"
}

// latestOther is the most recently used recent folder besides this one.
func (m FolderPicker) latestOther() string {
	best, at := "", int64(0)
	for _, row := range m.rows {
		if row.recent && row.age != nil && *row.age > at && row.path != m.workspace() {
			best, at = row.path, *row.age
		}
	}
	return best
}

// where is the folder a row is in, led by its host when it is remote; a
// host row says where the host is known from.
func (m FolderPicker) where(row folderRow) string {
	switch {
	case row.hostRow && row.source == "config":
		return "ssh config"
	case row.hostRow:
		return "recent host"
	}
	host, p := daemon.SplitLocation(row.path)
	if host == "" {
		return strings.Join(crumbParts(m.homed(path.Dir(p))), " › ")
	}
	// the host leads the first crumb, as in the preview's rule
	crumbs := crumbParts(scpRelative(underHome(path.Dir(p), m.homes[m.canonical(host)])))
	crumbs[0] = cmp.Or(row.host, m.labelOf(host)) + ":" + crumbs[0]
	return strings.Join(crumbs, " › ")
}

// reach is a remote row's host state where its head and age would go:
// nothing once ready or while warming (the row is faint then), what is
// wrong otherwise, and the way in when a person must sign in.
func (m FolderPicker) reach(row folderRow) (note string, style lipgloss.Style, dim bool) {
	p := m.probe(row.hostKey)
	switch p.State {
	case "warming":
		return "", DefaultStyles.Faint, true
	case "needs_auth":
		return "sign in · ctrl+l", DefaultStyles.Warning, false
	case "unreachable", "unsupported":
		return cmp.Or(p.Detail, p.State), DefaultStyles.Error, false
	}
	return "", DefaultStyles.Faint, false
}

// row is a folder in the sessions view's grammar: bar, glyph, name with
// the matched letters lit, then quiet columns for where, head and age.
func (m FolderPicker) row(row folderRow, selected, here, latest bool, width int, now time.Time) string {
	glyph, glyphStyle := "· ", DefaultStyles.Faint
	switch {
	case selected:
		glyph, glyphStyle = "◆ ", DefaultStyles.Agent
	case here:
		glyph = "○ "
	case latest:
		glyph, glyphStyle = "● ", DefaultStyles.Success
	}
	whereW, tagW, ageW := 0, 12, 4
	if (row.recent || row.hostRow) && width >= 48 {
		whereW = 16
	}
	nameW := min(18, max(4, width-4-(whereW+2)-(tagW+2)-(ageW+2)))
	bar := " "
	if selected {
		bar = selectBar()
	}
	note, noteStyle, dim := m.reach(row)
	base := lipgloss.NewStyle()
	switch {
	case dim:
		base = DefaultStyles.Faint
	case selected:
		base = DefaultStyles.Bold
	}
	line := bar + glyphStyle.Render(glyph) + " " + litName(row.name, row.matched, nameW, base)
	if whereW > 0 {
		line += "  " + DefaultStyles.Faint.Render(svCell(m.where(row), whereW, false))
	}
	if note != "" {
		line += "  " + noteStyle.Render(svCell(note, tagW+2+ageW, false))
		if selected {
			return selectedLine(line, width)
		}
		return line
	}
	line += "  " + DefaultStyles.Faint.Render(svCell(repoTag(m.repos[row.path]), tagW, false))
	age := ""
	if here {
		age = "here"
	} else if row.age != nil {
		age = svCompactAge(row.age, now)
	}
	line += "  " + DefaultStyles.Faint.Render(svCell(age, ageW, true))
	if selected {
		return selectedLine(line, width)
	}
	return line
}

// litName fits name into w columns in base, its fuzzy-matched letters lit.
func litName(name string, matched []int, w int, base lipgloss.Style) string {
	lit := DefaultStyles.Prompt.Bold(true).Underline(true)
	fitted := ansi.Truncate(name, w, "…")
	var b strings.Builder
	for i, r := range fitted {
		style := base
		if slices.Contains(matched, i) {
			style = lit
		}
		b.WriteString(style.Render(string(r)))
	}
	return b.String() + strings.Repeat(" ", max(0, w-ansi.StringWidth(fitted)))
}

// crumbParts splits a homed path into the folders it passes through.
func crumbParts(p string) []string {
	if p == "/" {
		return []string{"/"}
	}
	if strings.HasPrefix(p, "/") {
		return append([]string{"/"}, strings.Split(p[1:], "/")...)
	}
	return strings.Split(p, "/")
}

// repoTag is a list row's head: a git branch or detached commit, or a jj
// bookmark or change.
func repoTag(r *daemon.Repo) string {
	switch {
	case r == nil:
		return ""
	case r.Kind == "jj" && r.Bookmark != nil:
		return "⚑ " + r.Bookmark.Name
	case r.Kind == "jj":
		if r.Change != "" {
			return "@ " + r.Change
		}
		return ""
	}
	if r.Branch != "" || r.Commit != "" {
		return "⎇ " + cmp.Or(r.Branch, r.Commit)
	}
	return ""
}

// ── preview ────────────────────────────────────────────────────────────────

// preview is the highlighted folder in exactly height rows: its path
// over its languages, the repository as the root of a two-level tree, then
// the sessions working there.
func (m FolderPicker) preview(width, height int) []string {
	row, ok := m.highlighted()
	if !ok {
		if row = m.typedHost(); row.hostKey == "" {
			return make([]string, height)
		}
	}
	if row.hostRow || !m.reachable(row) {
		return m.hostPane(row, width, height)
	}
	c := m.previews[row.path]
	var body []string
	var languages []daemon.LanguageShare
	var tree *daemon.FolderPreview
	switch {
	case c == nil || c.loading:
		body = []string{DefaultStyles.Faint.Render("looking…")}
	case c.err:
		body = []string{DefaultStyles.Faint.Render("Could not open this folder")}
	default:
		languages, tree = c.Languages, &c.FolderPreview
		if c.Repo != nil {
			body = append(body, repoLine(c.Repo, time.Now()))
		}
	}
	// The tree fits around a third of the pane kept for the sessions, then
	// the sessions fill whatever the tree left.
	sessions := m.sessionsIn(row.path)
	if tree != nil {
		kept := 0
		if len(sessions) > 0 {
			kept = sessionHead + min(len(sessions), max(3, height/3))
		}
		body = append(body, fitTree(*tree, height-2-len(body)-kept)...)
	}
	lines := []string{m.paneRule(row.path, languages, width), ""}
	for _, l := range body {
		lines = append(lines, "  "+l)
	}
	lines = append(lines, m.sessionBlock(sessions, width, height-len(lines)-sessionHead)...)
	return append(lines, make([]string, max(0, height-len(lines)))...)[:height]
}

// hostPane is a host, or a folder on a host not reached yet: how the host
// answers, then what it runs and where ~ is once it is ready.
func (m FolderPicker) hostPane(row folderRow, width, height int) []string {
	p := m.probe(row.hostKey)
	label := m.labelOf(row.hostKey)
	var body []string
	switch p.State {
	case "", "warming":
		body = []string{DefaultStyles.Faint.Render(reachingText(label, p.Step)+" ") + DefaultStyles.Agent.Render(connectingFace(label, m.frame))}
	case "ready":
		if p.OS != "" {
			body = append(body, DefaultStyles.Muted.Render(strings.TrimSpace(p.OS+" "+p.Arch)))
		}
		if home := m.homes[m.canonical(row.hostKey)]; home != "" {
			body = append(body, DefaultStyles.Faint.Render("~ is ")+DefaultStyles.Muted.Render(home))
		}
	case "needs_auth":
		body = []string{DefaultStyles.Warning.Render(cmp.Or(p.Detail, "needs a person to sign in")), DefaultStyles.Faint.Render("ctrl+l signs in here")}
	default:
		body = []string{DefaultStyles.Error.Render(cmp.Or(p.Detail, p.State))}
	}
	lines := []string{DefaultStyles.Decor.Render("─ ") + hostStyle(label).Render(label) + " " + DefaultStyles.Decor.Render(strings.Repeat("─", max(0, width-3-ansi.StringWidth(label)))), ""}
	for _, l := range body {
		lines = append(lines, "  "+ansi.Truncate(l, max(0, width-2), "…"))
	}
	if !row.hostRow {
		lines = append(lines, m.sessionBlock(m.sessionsIn(row.path), width, height-len(lines)-sessionHead)...)
	}
	return append(lines, make([]string, max(0, height-len(lines)))...)[:height]
}

// sessionHead is the rows above the sessions: their rule between blanks.
const sessionHead = 3

// sessionBlock is the sessions working in the previewed folder under their
// rule, in at most room rows. Stepped into, it follows the cursor.
func (m FolderPicker) sessionBlock(sessions []daemon.Session, width, room int) []string {
	if len(sessions) == 0 || room <= 0 {
		return nil
	}
	now := time.Now()
	rows := make([]string, len(sessions))
	for i, s := range sessions {
		selected := m.inSessions && i == m.sessionCursor
		glyph, style := "· ", DefaultStyles.Faint
		switch {
		case selected:
			glyph, style = "◆ ", DefaultStyles.Agent
		case s.LastAssistantAt != nil && now.Sub(time.Unix(*s.LastAssistantAt, 0)) < time.Hour:
			glyph, style = "● ", DefaultStyles.Success
		}
		titleStyle := DefaultStyles.Muted
		bar := " "
		if selected {
			titleStyle = DefaultStyles.Bold
			bar = selectBar()
		}
		title := titleStyle.Render(sessionTitle(s))
		line := bar + " " + style.Render(glyph) + title
		if s.LastAssistantAt != nil {
			line += DefaultStyles.Faint.Render("  " + svCompactAge(s.LastAssistantAt, now))
		}
		if selected {
			line = selectedLine(line, width)
		}
		rows[i] = line
	}
	if len(rows) > room && !m.inSessions {
		rows = append(rows[:room-1], DefaultStyles.Faint.Render(fmt.Sprintf("   … %d more", len(sessions)-room+1)))
	}
	return append([]string{"", plainRule("sessions", width), ""}, scrollWindow(rows, m.sessionCursor, width, min(room, len(rows)))...)
}

func (m FolderPicker) sessionsIn(p string) []daemon.Session {
	return slices.DeleteFunc(slices.Clone(m.sessions), func(s daemon.Session) bool { return s.Workspace != p })
}

// paneRule heads the preview like sectionRule heads the list: the folder's
// breadcrumbs, then a rule split by language share, then the language that
// leads.
func (m FolderPicker) paneRule(p string, languages []daemon.LanguageShare, w int) string {
	parts := crumbParts(m.homed(p))
	lead := func() string { return DefaultStyles.Decor.Render("─ ") + crumbs(parts) + " " }
	tail := ""
	if len(languages) > 0 {
		tail = " " + languageStyle(languages[0].Name, knownLanguageColor(languages[0].Color)).Render(strings.ToLower(languages[0].Name)) + " "
	}
	for len(parts) > 2 && ansi.StringWidth(lead()+tail) > w-8 {
		parts = append([]string{"…"}, parts[2:]...)
	}
	n := max(0, w-ansi.StringWidth(lead())-ansi.StringWidth(tail))
	var rule strings.Builder
	used, sum := 0, 0.0
	for _, l := range languages {
		sum += l.Share
		k := min(n, int(float64(n)*sum+0.5)) - used
		rule.WriteString(languageStyle(l.Name, knownLanguageColor(l.Color)).Render(strings.Repeat("─", k)))
		used += k
	}
	rule.WriteString(DefaultStyles.Decor.Render(strings.Repeat("─", n-used)))
	return lead() + rule.String() + tail
}

// crumbs is a path as soft breadcrumbs, the leaf in bold.
func crumbs(parts []string) string {
	out := make([]string, len(parts))
	for i, p := range parts {
		out[i] = DefaultStyles.Muted.Bold(i == len(parts)-1).Render(p)
	}
	return strings.Join(out, DefaultStyles.Decor.Render(" › "))
}

// plainRule is a section rule without a count.
func plainRule(label string, w int) string {
	head := " " + label + " "
	return DefaultStyles.Decor.Render("─") + DefaultStyles.Muted.Bold(true).Render(head) + DefaultStyles.Decor.Render(strings.Repeat("─", max(0, w-1-ansi.StringWidth(head))))
}

// repoLine is the repository at the root of the tree: the head, how many
// files changed when any did, and when it was last touched.
func repoLine(r *daemon.Repo, now time.Time) string {
	var parts []string
	switch {
	case r.Kind == "jj":
		head := ""
		if r.Bookmark != nil {
			head = DefaultStyles.Agent.Render("⚑ " + r.Bookmark.Name)
			if r.Bookmark.Ahead > 0 {
				head += DefaultStyles.Faint.Render(fmt.Sprintf("+%d", r.Bookmark.Ahead))
			}
			parts = append(parts, head)
		}
		if r.Change != "" {
			parts = append(parts, DefaultStyles.Faint.Render("@ ")+DefaultStyles.Muted.Render(r.Change))
		}
	case r.Branch != "" || r.Commit != "":
		parts = append(parts, DefaultStyles.Agent.Render("⎇ "+cmp.Or(r.Branch, r.Commit)))
	}
	if r.Changed != nil && *r.Changed > 0 {
		parts = append(parts, DefaultStyles.Warning.Render(fmt.Sprintf("✎ %d", *r.Changed)))
	}
	if r.Touched != nil {
		parts = append(parts, DefaultStyles.Faint.Render(svCompactAge(r.Touched, now)))
	}
	return strings.Join(parts, "  ")
}

// fitTree is the preview's tree in at most rows lines. When the two levels
// do not fit, directories show fewer children, then none, and last the
// top level itself is cut short.
func fitTree(p daemon.FolderPreview, rows int) []string {
	for _, children := range []int{math.MaxInt, 2, 0} {
		if out := folderTree(p, children, len(p.Tree)); len(out) <= rows {
			return out
		}
	}
	for top := len(p.Tree) - 1; top > 0; top-- {
		if out := folderTree(p, 0, top); len(out) <= rows {
			return out
		}
	}
	return nil
}

// folderTree draws the preview's two levels, at most children under each
// directory and top entries in all: directories muted with a slash, files
// in their language's color, changes noted beside them. With no children
// shown, directories stand alone.
func folderTree(p daemon.FolderPreview, children, top int) []string {
	colors := map[string]string{}
	for _, l := range p.Languages {
		colors[l.Name] = knownLanguageColor(l.Color)
	}
	branch := func(last bool) string {
		text := "├─ "
		if last {
			text = "╰─ "
		}
		return DefaultStyles.Decor.Render(text)
	}
	more := func(n int) string { return DefaultStyles.Faint.Render(fmt.Sprintf("… %d more", n)) }
	name := func(n daemon.FolderNode) string {
		s := DefaultStyles.Muted.Render(n.Name) + DefaultStyles.Decor.Render("/")
		if !n.Dir {
			s = languageStyle(n.Language, colors[n.Language]).Render(n.Name)
		}
		if n.Changed > 0 {
			s += "  " + DefaultStyles.Faint.Render(fmt.Sprintf("✎ %d", n.Changed))
		}
		return s
	}
	tree, hidden := p.Tree[:min(top, len(p.Tree))], p.More+max(0, len(p.Tree)-top)
	var out []string
	for i, entry := range tree {
		last := i == len(tree)-1 && hidden == 0
		out = append(out, branch(last)+name(entry))
		if children == 0 {
			continue
		}
		indentText := "│  "
		if last {
			indentText = "   "
		}
		indent := DefaultStyles.Decor.Render(indentText)
		shown := entry.Children[:min(children, len(entry.Children))]
		rest := entry.More + len(entry.Children) - len(shown)
		for j, child := range shown {
			out = append(out, indent+branch(j == len(shown)-1 && rest == 0)+name(child))
		}
		if rest > 0 {
			out = append(out, indent+branch(true)+more(rest))
		}
	}
	if hidden > 0 {
		out = append(out, branch(true)+more(hidden))
	}
	return out
}

func knownLanguageColor(color *string) string {
	if color != nil {
		return *color
	}
	return ""
}
