package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"golang.org/x/text/language"
	"golang.org/x/text/message"
)

// ContextDetail is one section's content, read a page at a time and scrolled
// line by line.
type ContextDetail struct {
	Value   *daemon.ContextPage
	Error   string
	Section daemon.ContextSection
	Page    int
	Scroll  int
	// visible is the body rows the last frame drew; page jumps move by it.
	visible int
	// wrapped is wrappedFrom's content at wrappedWidth, kept because every
	// scroll step reads it and a page can be long.
	wrapped      []string
	wrappedWidth int
	wrappedFrom  *daemon.ContextPage
}

// rows is the page's content wrapped to width.
func (d *ContextDetail) rows(width int) []string {
	if d.Value == nil {
		return nil
	}
	if d.wrappedFrom != d.Value || d.wrappedWidth != width {
		d.wrapped, d.wrappedWidth, d.wrappedFrom = wrapContextContent(d.Value.Content, width), width, d.Value
	}
	return d.wrapped
}

// scroll moves the content by lines, within the rows the last frame showed.
func (d *ContextDetail) scroll(by int) {
	d.Scroll = min(max(0, d.Scroll+by), max(0, len(d.wrapped)-d.visible))
}

// list is the reader's body at exactly width × height: where the page comes
// from, any warning, then the scrolled rows.
func (d *ContextDetail) list(width, height int) []string {
	sec := d.Section
	head := []string{DefaultStyles.Faint.Render(fmt.Sprintf("%s · page %d/%d · %s", sec.Source, d.Page+1, sec.Pages, contextCount(sec.ByteCount, "byte")))}
	var rows []string
	switch {
	case d.Error != "":
		head = append(head, DefaultStyles.Error.Render(d.Error))
	case d.Value == nil:
		head = append(head, DefaultStyles.Faint.Render("loading inspectable prepared content…"))
	default:
		if d.Value.Omitted != "" {
			head = append(head, DefaultStyles.Warning.Render("omitted: "+d.Value.Omitted))
		}
		head = append(head, "")
		rows = d.rows(max(1, width-2))
	}
	room := max(0, height-len(head))
	d.visible = room
	d.Scroll = min(d.Scroll, max(0, len(rows)-room))

	out := make([]string, 0, height)
	for _, line := range head {
		out = append(out, "  "+line)
	}
	for _, row := range rows[d.Scroll:min(len(rows), d.Scroll+room)] {
		out = append(out, "  "+row)
	}
	for len(out) < height {
		out = append(out, "")
	}
	return out
}

type ContextDoneMsg struct{}

type contextSnapshotLoadedMsg struct {
	Snapshot *daemon.ContextSnapshot
	Err      error
	Gen      int
}

type contextPageLoadedMsg struct {
	Err       error
	Data      *daemon.ContextPage
	SectionID string
	Page      int
	Gen       int
}

// ContextInspectorModel lists the sections of the prepared request beside
// the highlighted section's facts. Enter reads a section's content.
type ContextInspectorModel struct {
	Conn      *daemon.Connection
	SessionID string
	Snapshot  *daemon.ContextSnapshot
	Detail    *ContextDetail
	pageStatus
	listView
}

func NewContextInspectorModel(conn *daemon.Connection, sessionID string) ContextInspectorModel {
	return ContextInspectorModel{
		Conn:       conn,
		SessionID:  sessionID,
		pageStatus: newPageStatus(true),
		listView:   newListView("Search sections"),
	}
}

func (m *ContextInspectorModel) SetSize(width, height int) {
	m.pageStatus.SetSize(width, height)
	m.listView.setSize(width, height)
}

func (m ContextInspectorModel) Init() tea.Cmd {
	return m.loadSnapshotCmd(m.Generation)
}

var compactionStatuses = map[string]string{
	"not_configured": "not configured", "not_needed": "not needed", "compacted": "applied", "unknown": "state unavailable",
}

func (m ContextInspectorModel) loadSnapshotCmd(gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return contextSnapshotLoadedMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}

		snapshot, err := daemon.GetContextSnapshot(context.Background(), m.Conn, m.SessionID)
		if err != nil {
			return contextSnapshotLoadedMsg{Err: err, Gen: gen}
		}
		return contextSnapshotLoadedMsg{Snapshot: &snapshot, Gen: gen}
	}
}

func (m ContextInspectorModel) loadPageCmd(sectionID string, page int, gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return contextPageLoadedMsg{SectionID: sectionID, Page: page, Err: errors.New("daemon connection unavailable"), Gen: gen}
		}
		data, err := daemon.GetContextPage(context.Background(), m.Conn, m.SessionID, m.Snapshot.SnapshotID, sectionID, page)
		if err != nil {
			return contextPageLoadedMsg{SectionID: sectionID, Page: page, Err: err, Gen: gen}
		}
		return contextPageLoadedMsg{SectionID: sectionID, Page: page, Data: &data, Gen: gen}
	}
}

// current is the section under the cursor.
func (m ContextInspectorModel) current() (daemon.ContextSection, bool) {
	row, ok := m.highlighted()
	if !ok || m.Snapshot == nil {
		return daemon.ContextSection{}, false
	}
	i := slices.IndexFunc(m.Snapshot.Sections, func(sec daemon.ContextSection) bool { return sec.ID == row.key })
	if i < 0 {
		return daemon.ContextSection{}, false
	}
	return m.Snapshot.Sections[i], true
}

func (m *ContextInspectorModel) setSections() {
	var rows []listEntry
	if m.Snapshot != nil {
		rows = make([]listEntry, len(m.Snapshot.Sections))
		for i, sec := range m.Snapshot.Sections {
			rows[i] = sectionEntry(i, sec)
		}
	}
	m.setRows(rows)
}

func sectionEntry(i int, sec daemon.ContextSection) listEntry {
	tag := DefaultStyles.Faint.Render("no content")
	if sec.Pages > 0 {
		tag = DefaultStyles.Muted.Render(contextCount(sec.Pages, "page"))
	}
	return listEntry{
		key:    sec.ID,
		lead:   DefaultStyles.Faint.Render(fmt.Sprintf("%d.", i+1)),
		name:   sec.Label,
		desc:   sec.Source,
		tag:    tag,
		search: []string{sec.Kind, sec.Preview},
		detail: func(width int) []string { return sectionDetails(sec, width) },
	}
}

// sectionDetails is the pane: where a section comes from, how much of it
// there is, and its preview.
func sectionDetails(sec daemon.ContextSection, width int) []string {
	pages := "content unavailable"
	if sec.Pages > 0 {
		pages = contextCount(sec.Pages, "page")
	}
	lines := paneTitle(sec.Label, "", width)
	lines = append(lines, factRows("source", sec.Source, width)...)
	lines = append(lines, factRows("items", contextCount(sec.ItemCount, "item"), width)...)
	lines = append(lines, factRows("bytes", contextCount(sec.ByteCount, "measured byte"), width)...)
	lines = append(lines, factRows("pages", pages, width)...)
	if sec.Preview != "" {
		lines = append(lines, "")
		lines = append(lines, factRows("preview", sec.Preview, width)...)
	}
	lines = append(lines, "")
	return append(lines, paneNote("enter reads this section a page at a time", width)...)
}

// requestFacts is the prepared request's standing, drawn above the sections
// so it reads without opening one.
func (m ContextInspectorModel) requestFacts(width int) []string {
	snap := m.Snapshot
	if snap == nil {
		return nil
	}
	if snap.State == "pending" {
		value := "not prepared for this running session yet"
		if snap.Reason != "" {
			value += ". " + snap.Reason
		}
		return factRows("request", value, width)
	}
	label := snap.Model
	if snap.Provider != "" {
		label = snap.Provider + " · " + snap.Model
	}
	if snap.Protocol != "" {
		label += " · " + snap.Protocol
	}
	window := "not reported"
	if snap.ContextWindowTokens != nil {
		window = contextCount(*snap.ContextWindowTokens, "token") + " (configured)"
	}
	compaction := snap.Compaction
	lines := factRows("model", label, width)
	lines = append(lines, factRows("window", window, width)...)
	strategy := cmp.Or(compaction.Strategy, "none")
	if status := compactionStatuses[compaction.Status]; status != "" {
		strategy += " · " + status
	}
	lines = append(lines, factRows("compact", strategy, width)...)
	if compaction.TriggerFreePercent != nil {
		lines = append(lines, factRows("trigger", fmt.Sprintf("keep %g%% free", *compaction.TriggerFreePercent), width)...)
	}
	switch {
	case compaction.ProviderInputTokens != nil:
		measured := contextCount(*compaction.ProviderInputTokens, "token") + " from provider"
		if compaction.ProviderCachedInputTokens != nil {
			measured += " · " + contextCount(*compaction.ProviderCachedInputTokens, "cached token")
		}
		lines = append(lines, factRows("input", measured, width)...)
	case compaction.EstimatedInputTokens != nil:
		method := cmp.Or(compaction.EstimateMethod, "method not reported")
		lines = append(lines, factRows("input", contextCount(*compaction.EstimatedInputTokens, "token")+" estimated · "+method, width)...)
	}
	return lines
}

// emptyText says why there are no section rows.
func (m ContextInspectorModel) emptyText() string {
	switch {
	case m.Loading && m.Snapshot == nil:
		return "loading prepared request snapshot…"
	case m.Snapshot == nil:
		return "no prepared request to inspect"
	case m.Snapshot.State == "pending":
		return "sections appear once a request is prepared"
	}
	return "the prepared request contains no inspectable sections"
}

// list draws the request's standing above the sections, then the sections,
// at exactly width × height.
func (m ContextInspectorModel) list(width, height int) []string {
	head := append(m.requestFacts(width), paneNote("read-only · durable transcript and request-only context are separate", width)...)
	head = append(head, "")
	for i := range head {
		head[i] = svFit(head[i], width)
	}
	lv := m.listView
	lv.Empty = m.emptyText()
	return append(head, lv.list(width, max(1, height-len(head)))...)
}

func (m ContextInspectorModel) footer(width int) string {
	hints := []hint{{"↑↓", "move"}, {"enter", "inspect"}, {"ctrl+r", "refresh"}, {"esc", "back"}}
	var status string
	urgent := true
	switch {
	case m.Error != "":
		status = DefaultStyles.Error.Render(m.Error)
	case m.Loading:
		status, urgent = DefaultStyles.Faint.Render("loading…"), false
	case m.Snapshot != nil:
		status, urgent = DefaultStyles.Faint.Render(counted(len(m.Snapshot.Sections), "section")), false
	}
	return footerLine(width, hints, status, urgent)
}

// readerFooter is the footer while a section's content is open.
func readerFooter(width int) string {
	return footerLine(width, []hint{{"↑↓", "scroll"}, {"pgup/pgdn", "jump"}, {"←→", "page"}, {"esc", "sections"}}, "", false)
}

func (m ContextInspectorModel) Update(msg tea.Msg) (ContextInspectorModel, tea.Cmd) {
	switch msg := msg.(type) {
	case contextSnapshotLoadedMsg:
		if !m.settle(msg.Gen, msg.Err, &m.Loading) {
			return m, nil
		}
		m.Snapshot, m.Error = msg.Snapshot, ""
		m.setSections()
		return m, nil

	case contextPageLoadedMsg:
		if msg.Gen != m.Generation || m.Detail == nil || m.Detail.Section.ID != msg.SectionID || m.Detail.Page != msg.Page {
			return m, nil
		}
		if msg.Err != nil {
			m.Detail.Error = msg.Err.Error()
		} else {
			m.Detail.Value, m.Detail.Error = msg.Data, ""
		}
		return m, nil

	case tea.KeyPressMsg:
		if m.Detail != nil {
			return m.readerKey(msg)
		}
		return m.sectionsKey(msg)
	}
	cmd := m.listView.update(msg)
	return m, cmd
}

// readerKey scrolls and pages through a section's content; esc returns to
// the sections.
func (m ContextInspectorModel) readerKey(msg tea.KeyPressMsg) (ContextInspectorModel, tea.Cmd) {
	d := m.Detail
	switch msg.String() {
	case "esc", "ctrl+c", "ctrl+d":
		m.Detail = nil
		m.Generation = nextPageGeneration()
	case "up":
		d.scroll(-1)
	case "down":
		d.scroll(1)
	case "pgup":
		d.scroll(-max(1, d.visible))
	case "pgdown":
		d.scroll(max(1, d.visible))
	case "left", "right":
		page := d.Page - 1
		if msg.String() == "right" {
			page = d.Page + 1
		}
		if page >= 0 && page < d.Section.Pages {
			d.Page, d.Value, d.Scroll, d.Error = page, nil, 0, ""
			m.Generation = nextPageGeneration()
			return m, m.loadPageCmd(d.Section.ID, page, m.Generation)
		}
	}
	return m, nil
}

func (m ContextInspectorModel) sectionsKey(msg tea.KeyPressMsg) (ContextInspectorModel, tea.Cmd) {
	switch msg.String() {
	case "esc", "ctrl+c", "ctrl+d":
		return m, func() tea.Msg { return ContextDoneMsg{} }
	case "enter":
		if sec, ok := m.current(); ok && sec.Pages > 0 {
			m.Detail = &ContextDetail{Section: sec}
			m.Generation = nextPageGeneration()
			return m, m.loadPageCmd(sec.ID, 0, m.Generation)
		}
		return m, nil
	case "ctrl+r":
		m.Loading, m.Snapshot, m.Error = true, nil, ""
		m.setSections()
		m.Generation = nextPageGeneration()
		return m, m.loadSnapshotCmd(m.Generation)
	}
	cmd := m.listView.update(msg)
	return m, cmd
}

func wrapContextContent(content string, width int) []string {
	if width <= 1 {
		width = 76
	}
	return strings.Split(ansi.Wrap(content, width, " "), "\n")
}

var englishPrinter = message.NewPrinter(language.English)

func contextCount(n int, unit string) string {
	if n != 1 {
		unit += "s"
	}
	return englishPrinter.Sprintf("%d", n) + " " + unit
}

// reader is the section's content as a list with no filter and no pane.
func (m ContextInspectorModel) reader() listFrame {
	title := brand("albedo") + " " + DefaultStyles.Muted.Render("/context")
	return listFrame{
		title:  title,
		right:  DefaultStyles.Faint.Render(m.Detail.Section.Label),
		list:   m.Detail.list,
		footer: readerFooter(max(1, m.Width)),
	}
}

func (m ContextInspectorModel) View() string {
	if m.Detail != nil {
		return m.reader().view(m.Width, m.Height)
	}
	title := brand("albedo") + " " + DefaultStyles.Muted.Render("/context")
	f := m.listView.frame(title, DefaultStyles.Faint.Render("prepared request"), m.footer(max(1, m.Width)))
	f.list = m.list
	return f.view(m.Width, m.Height)
}
