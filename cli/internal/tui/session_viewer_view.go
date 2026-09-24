package tui

import (
	"albedo/cli/internal/daemon"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// ── logo ───────────────────────────────────────────────────────────────────

// A four-point sparkle with a small companion star, drawn with half blocks so
// each pixel is roughly square.
var svLogoPixels = []string{
	"........#...............",
	"........#...........#...",
	".......###..........#...",
	".......###........#####.",
	"......#####.........#...",
	".....#######........#...",
	"...###########..........",
	"#################.......",
	"...###########..........",
	".....#######............",
	"......#####.............",
	".......###.........#....",
	".......###..............",
	"........#...............",
	"........#...............",
	"........................",
}

func svLogo() []string {
	rows := len(svLogoPixels) / 2
	width := len(svLogoPixels[0])
	lines := make([]string, rows)
	for r := 0; r < rows; r++ {
		var b strings.Builder
		for c := 0; c < width; c++ {
			top := svLogoPixels[2*r][c] == '#'
			bottom := svLogoPixels[2*r+1][c] == '#'
			ch := " "
			switch {
			case top && bottom:
				ch = "█"
			case top:
				ch = "▀"
			case bottom:
				ch = "▄"
			}
			if ch == " " {
				b.WriteString(ch)
				continue
			}
			// Diagonal sweep so the gradient reads as light glancing off the mark.
			t := (float64(c)/float64(width) + float64(r)/float64(rows)) / 2
			b.WriteString(brandInk(t).Render(ch))
		}
		lines[r] = b.String()
	}
	return lines
}

// ── helpers ────────────────────────────────────────────────────────────────

func svCompactAge(ts *int64, now time.Time) string {
	if ts == nil {
		return "—"
	}
	d := now.Sub(time.Unix(*ts, 0))
	switch {
	case d < time.Minute:
		return "now"
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	case d < 14*24*time.Hour:
		return fmt.Sprintf("%dd", int(d.Hours()/24))
	case d < 60*24*time.Hour:
		return fmt.Sprintf("%dw", int(d.Hours()/24/7))
	}
	return fmt.Sprintf("%dmo", int(d.Hours()/24/30))
}

// svCell fits plain text into exactly w columns.
func svCell(s string, w int, right bool) string {
	if w <= 0 {
		return ""
	}
	s = ansi.Truncate(s, w, "…")
	pad := strings.Repeat(" ", max(0, w-ansi.StringWidth(s)))
	if right {
		return pad + s
	}
	return s + pad
}

type svColumns struct {
	title, model, workspace, age int
}

func svLayout(width int) svColumns {
	// Row: bar(1) icon(2) space(1) title … model … workspace … age, two-space gaps.
	cols := svColumns{}
	rest := width - 4
	if width >= 32 {
		cols.age = 4
		rest -= cols.age + 2
	}
	if width >= 56 {
		cols.model = min(20, max(14, width/5))
		rest -= cols.model + 2
	}
	if width >= 90 {
		cols.workspace = min(18, max(10, width/8))
		rest -= cols.workspace + 2
	}
	cols.title = max(1, rest-1)
	return cols
}

// svSep divides the columns.
func svSep() string { return DefaultStyles.Decor.Render(" │ ") }

// ── view ───────────────────────────────────────────────────────────────────

// View lays the screen out by width: favourites | recent | preview when there
// is room for all three, one list beside the preview below that, and the list
// alone on narrow terminals.
func (m SessionViewer) View() string {
	width := m.Width
	if width <= 0 {
		width = 80
	}
	height := m.Height
	if height <= 0 {
		height = 24
	}
	now := m.clock()
	roomy := height >= 12

	lines := []string{m.titleRule(width)}
	if roomy {
		lines = append(lines, "")
	}
	lines = append(lines, " "+promptLead()+m.SearchInput.View())
	if height >= 9 {
		lines = append(lines, "")
	}
	tail := []string{m.footer(width, now)}
	if roomy {
		tail = append([]string{""}, tail...)
	}
	body := max(1, height-len(lines)-len(tail))

	var favourites, recent, all []int
	for i := range m.Filtered {
		all = append(all, i)
		if m.favourite(i) {
			favourites = append(favourites, i)
		} else {
			recent = append(recent, i)
		}
	}

	var columns [][]string
	switch {
	case width >= 150 && height >= 14:
		favW := min(44, max(30, width*24/100))
		recW := min(64, max(40, width*34/100))
		prevW := width - favW - recW - 2*ansi.StringWidth(svSep())
		columns = [][]string{
			m.column(favourites, favW, body, now, true),
			m.column(recent, recW, body, now, false),
			m.preview(prevW, body, now),
		}
	case width >= 96 && height >= 14:
		listW := width / 2
		columns = [][]string{
			m.column(all, listW, body, now, false),
			m.preview(width-listW-ansi.StringWidth(svSep()), body, now),
		}
	default:
		columns = [][]string{m.column(all, width, body, now, false)}
	}
	for row := 0; row < body; row++ {
		var b strings.Builder
		for c, col := range columns {
			if c > 0 {
				b.WriteString(svSep())
			}
			b.WriteString(col[row])
		}
		lines = append(lines, b.String())
	}
	lines = append(lines, tail...)

	if len(lines) > height {
		lines = append(lines[:max(0, height-1)], lines[len(lines)-1])
	}
	for i, l := range lines {
		lines[i] = ansi.Truncate(l, width, "…")
	}
	return strings.Join(lines, "\n")
}

// svFit pads or cuts a styled line to exactly w columns.
func svFit(s string, w int) string {
	s = ansi.Truncate(s, w, "…")
	return s + strings.Repeat(" ", max(0, w-ansi.StringWidth(s)))
}

// titleRule is the brand at the workspace over a rule.
func (m SessionViewer) titleRule(width int) string {
	label := "albedo"
	if m.ArchiveView {
		label = "albedo  archive"
	}
	return " " + titleRule(width-1, located(label, sessionText(homePath(m.Workspace))), "")
}

func (m SessionViewer) footer(width int, now time.Time) string {
	esc := "quit"
	if m.HasActive {
		esc = "back"
	}
	left := " " + keyHints(hint{"↑↓", "move"}, hint{"tab", "switch"}, hint{"enter", "open"}, hint{"^s", "pin"}, hint{"^a", "archive"}, hint{"esc", esc})
	if m.ArchiveView {
		left = " " + keyHints(hint{"↑↓", "move"}, hint{"enter", "open"}, hint{"^a", "restore"}, hint{"^d", "delete"}, hint{"esc", "back"})
	}
	if m.ConfirmDelete != "" {
		return " " + DefaultStyles.Error.Render("Permanently delete session and its data? y to confirm · any other key cancels")
	}

	var right string
	if m.notice != "" {
		right = DefaultStyles.Error.Render(m.notice)
	} else if m.Loading {
		right = DefaultStyles.Faint.Render("loading…")
	} else {
		today := 0
		for _, s := range m.Sessions {
			if dateSection(s, now) == secToday {
				today++
			}
		}
		count := len(m.Sessions)
		if m.ArchiveView {
			count = len(m.prefs.Archived)
			today = 0
		}
		right = DefaultStyles.Faint.Render(fmt.Sprintf("%d sessions", count))
		if today > 0 {
			right += DefaultStyles.Decor.Render(" · ") + DefaultStyles.Success.Render(fmt.Sprintf("%d today", today))
		}
	}
	gap := width - ansi.StringWidth(left) - ansi.StringWidth(right) - 1
	if gap < 3 {
		return left
	}
	return left + strings.Repeat(" ", gap) + right
}

// column renders Filtered[indices] with section headings at exactly
// width × height, scrolled to keep the cursor visible.
func (m SessionViewer) column(indices []int, width, height int, now time.Time, favourites bool) []string {
	cols := svLayout(width)
	counts := map[int]int{}
	for _, i := range indices {
		counts[m.section[m.Filtered[i].ID]]++
	}
	var all []string
	selectedAt := -1
	section := -1
	for _, i := range indices {
		item := m.Filtered[i]
		sec := m.section[item.ID]
		if sec != section && sec != secAction {
			if len(all) > 0 && height >= 10 {
				all = append(all, "")
			}
			all = append(all, sectionRule(sectionTitles[sec], counts[sec], width))
		}
		section = sec
		if i == m.Cursor {
			selectedAt = len(all)
		}
		s, _ := m.session(item.ID)
		all = append(all, m.row(item, s, sec, i == m.Cursor, width, cols, now))
	}
	switch {
	case favourites && counts[secPinned]+counts[secFrequent] == 0 && m.SearchInput.Value() == "":
		all = append(all, "", DefaultStyles.Faint.Render("   ★ nothing pinned yet"), "",
			DefaultStyles.Faint.Render("   highlight a session and press"),
			DefaultStyles.Faint.Render("   ")+DefaultStyles.Muted.Render("ctrl+s")+DefaultStyles.Faint.Render(" to keep it here."),
			"", DefaultStyles.Faint.Render("   sessions you open often"),
			DefaultStyles.Faint.Render("   show up here on their own."))
	case len(indices) == 0 && m.ArchiveView && m.SearchInput.Value() == "":
		all = append(all, DefaultStyles.Faint.Render("   archive is empty"))
	case len(indices) == 0 && m.Loading:
		all = append(all, DefaultStyles.Faint.Render("   loading sessions…"))
	case len(indices) == 0:
		all = append(all, DefaultStyles.Faint.Render("   no matches"))
	}

	if len(all) > height {
		start := 0
		if selectedAt >= 0 {
			start = selectedAt - height/2
		}
		start = min(max(0, start), len(all)-height)
		window := append([]string(nil), all[start:start+height]...)
		if height >= 3 {
			more := DefaultStyles.Faint.Render("   ···")
			if start > 0 {
				window[0] = more
			}
			if start+height < len(all) {
				window[len(window)-1] = more
			}
		}
		all = window
	}
	out := make([]string, height)
	for i := range out {
		if i < len(all) {
			out[i] = svFit(all[i], width)
		} else {
			out[i] = strings.Repeat(" ", width)
		}
	}
	return out
}

func (m SessionViewer) row(item PickerItem, s daemon.Session, sec int, selected bool, width int, cols svColumns, now time.Time) string {
	st := func(style lipgloss.Style) lipgloss.Style {
		if selected {
			return style.Inherit(DefaultStyles.Selected)
		}
		return style
	}
	bar := st(lipgloss.NewStyle()).Render(" ")
	if selected {
		bar = st(DefaultStyles.Agent).Render("▌")
	}
	titleStyle := lipgloss.NewStyle()
	if selected {
		titleStyle = DefaultStyles.Bold
	}
	fill := func(line string) string {
		if pad := width - ansi.StringWidth(line); pad > 0 {
			line += st(lipgloss.NewStyle()).Render(strings.Repeat(" ", pad))
		}
		return line
	}

	if sec == secAction {
		glyph, title, hint, fg := "✦ ", "New session", "in "+sessionText(filepath.Base(m.Workspace)), DefaultStyles.You
		if item.ID == "archive" {
			glyph, title, hint, fg = "▤ ", "Archive", fmt.Sprintf("%d sessions", len(m.prefs.Archived)), DefaultStyles.Muted
		} else if item.ID == "login" {
			glyph, title, hint, fg = "◇ ", "Accounts", "providers", DefaultStyles.Muted
		}
		titleWidth := min(ansi.StringWidth(title), cols.title)
		return fill(bar + st(fg).Render(glyph) + st(lipgloss.NewStyle()).Render(" ") +
			st(titleStyle.Inherit(fg)).Render(svCell(title, titleWidth, false)) +
			st(DefaultStyles.Faint).Render(svCell("  "+hint, max(0, width-4-titleWidth), false)))
	}

	recent := s.LastAssistantAt != nil && now.Sub(time.Unix(*s.LastAssistantAt, 0)) < time.Hour
	glyph, iconStyle := "· ", DefaultStyles.Faint
	switch {
	case selected:
		glyph, iconStyle = "◆ ", DefaultStyles.Agent
	case sec == secPinned:
		glyph, iconStyle = "★ ", DefaultStyles.Agent
	case recent:
		glyph, iconStyle = "● ", DefaultStyles.Success
	}
	gap := st(lipgloss.NewStyle()).Render("  ")
	line := bar + st(iconStyle).Render(glyph) + st(lipgloss.NewStyle()).Render(" ") + st(titleStyle).Render(svCell(item.Label, cols.title, false))
	if cols.model > 0 {
		model := sessionText(s.Model)
		if model == "" {
			model = "—"
		}
		ms := DefaultStyles.Muted
		if selected {
			ms = lipgloss.NewStyle()
		}
		line += gap + st(ms).Render(svCell(model, cols.model, false))
	}
	if cols.workspace > 0 {
		wsStyle := DefaultStyles.Muted
		if s.Workspace == m.Workspace {
			wsStyle = DefaultStyles.Faint
		}
		line += gap + st(wsStyle).Render(svCell(sessionText(filepath.Base(s.Workspace)), cols.workspace, false))
	}
	if cols.age > 0 {
		as := DefaultStyles.Faint
		if recent {
			as = DefaultStyles.Success
		}
		line += gap + st(as).Render(svCell(svCompactAge(s.LastAssistantAt, now), cols.age, true))
	}
	return fill(line)
}

// ── preview ────────────────────────────────────────────────────────────────

// preview renders the highlighted row's pane at exactly width × height: the
// session's title and metadata over its latest turns, newest at the bottom.
func (m SessionViewer) preview(width, height int, now time.Time) []string {
	inner := max(1, width-2)
	var top, bottom []string
	item, ok := m.Highlighted()
	s, isSession := m.session(item.ID)
	switch {
	case !ok:
		top = []string{"", DefaultStyles.Muted.Render("nothing matches"), DefaultStyles.Faint.Render("try fewer words")}
	case !isSession:
		top = m.actionPreview(item.ID, inner, height)
	default:
		for _, l := range svWrap(sessionTitle(s), inner, 2) {
			top = append(top, DefaultStyles.Bold.Render(l))
		}
		meta := []string{}
		if m.prefs.pinned(s.ID) {
			meta = append(meta, DefaultStyles.Agent.Render("★ pinned"))
		}
		if s.Model != "" {
			meta = append(meta, DefaultStyles.Muted.Render(sessionText(s.Model)))
		}
		if s.Workspace != "" {
			meta = append(meta, DefaultStyles.Muted.Render(sessionText(homePath(s.Workspace))))
		}
		meta = append(meta, DefaultStyles.Faint.Render(daemon.AssistantAge(s.LastAssistantAt, now)))
		if c := m.previews[s.ID]; c != nil && !c.loading && !c.err {
			meta = append(meta, DefaultStyles.Faint.Render(fmt.Sprintf("%d messages", c.Total)))
		}
		top = append(top, strings.Join(meta, DefaultStyles.Decor.Render(" · ")), DefaultStyles.Decor.Render(strings.Repeat("─", inner)))
		bottom = m.transcript(s, inner, max(0, height-len(top)-1))
	}

	out := make([]string, 0, height)
	for _, l := range append(top, bottom...) {
		if len(out) == height {
			break
		}
		out = append(out, " "+svFit(l, inner)+" ")
	}
	for len(out) < height {
		out = append(out, strings.Repeat(" ", width))
	}
	return out
}

// actionPreview is a centred splash for the New session and Accounts rows.
func (m SessionViewer) actionPreview(id string, inner, height int) []string {
	var lines []string
	if id == "new" {
		if logo := svLogo(); height >= len(logo)+8 {
			lines = append(append(lines, ""), logo...)
		}
		lines = append(lines, "", gradientText("New session", true), "",
			DefaultStyles.Muted.Render("start fresh in ")+lipgloss.NewStyle().Render(sessionText(homePath(m.Workspace))), "",
			DefaultStyles.Faint.Render("enter ")+DefaultStyles.Muted.Render("begin"))
	} else if id == "archive" {
		lines = append(lines, "", "", DefaultStyles.Muted.Bold(true).Render("▤ Archive"), "",
			DefaultStyles.Muted.Render("Sessions kept out of the main list."), "",
			DefaultStyles.Faint.Render("enter ")+DefaultStyles.Muted.Render("browse"))
	} else {
		lines = append(lines, "", "", DefaultStyles.Muted.Bold(true).Render("◇ Accounts"), "",
			DefaultStyles.Muted.Render("add a provider, sign in, or pick"), DefaultStyles.Muted.Render("which one new sessions use."), "",
			DefaultStyles.Faint.Render("enter ")+DefaultStyles.Muted.Render("manage"))
	}
	for i, l := range lines {
		lines[i] = strings.Repeat(" ", max(0, (inner-ansi.StringWidth(l))/2)) + l
	}
	return lines
}

// transcript is the tail of the session's conversation in at most height lines.
func (m SessionViewer) transcript(s daemon.Session, width, height int) []string {
	if height <= 0 {
		return nil
	}
	c := m.previews[s.ID]
	note := func(lines ...string) []string {
		out := []string{""}
		for _, l := range lines {
			out = append(out, DefaultStyles.Faint.Render(l))
		}
		return out
	}
	switch {
	case m.Fetch == nil:
		return nil
	case c == nil || c.loading:
		return note("loading conversation…")
	case c.err:
		return note("preview needs a newer daemon —", "run albedo daemon --stop, then reopen albedo.")
	case len(c.Items) == 0:
		return note("no messages yet")
	}

	// Consecutive tool calls collapse into one line of names with counts.
	type block struct {
		kind, text string
		tools      []string
		counts     map[string]int
	}
	var blocks []*block
	for _, it := range c.Items {
		text := sessionText(it.Preview)
		if it.Type == "assistant" {
			text = svMarkdownMarks.Replace(text)
		}
		if it.Type != "tool" {
			blocks = append(blocks, &block{kind: it.Type, text: text})
			continue
		}
		if len(blocks) == 0 || blocks[len(blocks)-1].kind != "tool" {
			blocks = append(blocks, &block{kind: "tool", counts: map[string]int{}})
		}
		b := blocks[len(blocks)-1]
		for _, name := range strings.Split(text, ", ") {
			if b.counts[name] == 0 {
				b.tools = append(b.tools, name)
			}
			b.counts[name]++
		}
	}
	for _, b := range blocks {
		for i, name := range b.tools {
			if n := b.counts[name]; n > 1 {
				b.tools[i] = fmt.Sprintf("%s ×%d", name, n)
			}
		}
		if b.kind == "tool" {
			b.text = strings.Join(b.tools, ", ")
		}
	}

	// the same rails as the transcript: one per turn, dimmer through tools
	r := NewTranscriptRenderer()
	lanes := map[string]lane{"user": laneYou, "assistant": laneAgent, "tool": laneBusy}
	var lines []string
	prev := laneNone
	for bi, b := range blocks {
		own := lanes[b.kind]
		textStyle, maxLines := lipgloss.NewStyle(), 3
		if b.kind == "tool" {
			textStyle, maxLines = DefaultStyles.Faint, 2
		}
		if bi > 0 && joint(prev, own) == laneNone {
			lines = append(lines, "")
		}
		for _, l := range svWrap(b.text, max(1, width-railWidth), maxLines) {
			lines = append(lines, r.rail(own)+textStyle.Render(l))
		}
		prev = own
	}
	lines = append([]string{""}, lines...)
	if len(lines) > height {
		lines = lines[len(lines)-height:]
		lines[0] = DefaultStyles.Faint.Render("··· earlier")
	}
	return lines
}

// svMarkdownMarks drops emphasis and code markers that only cost width in a
// one-paragraph excerpt.
var svMarkdownMarks = strings.NewReplacer("**", "", "__", "", "`", "")

// svWrap word-wraps plain text into at most maxLines lines of width columns.
func svWrap(text string, width, maxLines int) []string {
	lines := strings.Split(ansi.Wrap(text, width, " -"), "\n")
	if len(lines) > maxLines {
		lines = lines[:maxLines]
		last := strings.TrimRight(lines[maxLines-1], " ")
		lines[maxLines-1] = ansi.Truncate(last+" …", width, "…")
	}
	return lines
}
