package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

func formatUsage(u *daemon.Usage) string {
	if u == nil {
		return "—"
	}
	total := 0
	if u.TotalTokens != nil {
		total = *u.TotalTokens
	}
	rate := ""
	if u.TokensPerSecond != nil && *u.TokensPerSecond > 0 {
		rate = " · " + formatRate(*u.TokensPerSecond)
	}
	return formatTokens(total) + " tokens" + rate
}

func formatRate(tokensPerSecond float64) string {
	return fmt.Sprintf("%.1f tok/s", tokensPerSecond)
}

// formatCount is a token count in whole thousands: "34k", "1.2m".
func formatCount(val int) string {
	switch {
	case val >= 999_500:
		return fmt.Sprintf("%.1fm", float64(val)/1_000_000.0)
	case val >= 1_000:
		return fmt.Sprintf("%dk", (val+500)/1_000)
	default:
		return strconv.Itoa(val)
	}
}

func formatTokens(val int) string {
	switch {
	case val >= 1_000_000:
		return fmt.Sprintf("%.1fm", float64(val)/1_000_000.0)
	case val >= 1_000:
		return fmt.Sprintf("%.1fk", float64(val)/1_000.0)
	default:
		return strconv.Itoa(val)
	}
}

func (m ChatModel) padding() int {
	if m.Width >= 50 {
		return 2
	}
	return 1
}

func (m ChatModel) chatWidth() int { return max(1, m.Width-2*m.padding()) }

// sidebarWidth is 0 without glances or room for them. The transcript keeps at
// least 72 columns beside a sidebar of 20 to 32.
func (m ChatModel) sidebarWidth() int {
	room := m.chatWidth() - 72 - 2
	if room < 20 || len(m.activeGlances()) == 0 {
		return 0
	}
	return min(32, room)
}

// actionLabel is the action row for a call, live from its progress and then
// from its result, so the row holds the last action until the next begins.
func actionLabel(progress *daemon.ToolProgress, result *HistoryEntry) string {
	switch {
	case result != nil:
		head, tail := toolRowParts(*result, toolFailed(*result), "")
		return head + tail
	case progress.Phase == "generating":
		return "generating " + progress.Name
	case progress.Name == "python":
		if line := pythonSourceLine(progress.Code); line != "" {
			return "running " + line
		}
	}
	return "running " + progress.Name
}

// pythonSourceLine returns the first useful source line from a cell preview.
func pythonSourceLine(preview *daemon.ToolCodePreview) string {
	if preview == nil {
		return ""
	}
	for line := range strings.SplitSeq(preview.Text, "\n") {
		line = strings.TrimSpace(line)
		if line != "" && !strings.HasPrefix(line, "#") {
			return line
		}
	}
	return ""
}

// renderProgress holds the last tool action in one row; a call still being
// generated also shows the newest end of its code.
func (m ChatModel) renderProgress() string {
	width := max(1, m.Renderer.BodyWidth-railWidth)
	row := oneLine(m.toolLabel())
	if progress := m.latestProgress(); progress != nil && progress.Phase == "generating" && progress.Code != nil {
		code := progress.Code
		if text := oneLine(code.Text); text != "" {
			row += " · "
			if room := width - ansi.StringWidth(row); room >= 12 && ansi.StringWidth(text) > room {
				text = ansi.TruncateLeft(text, ansi.StringWidth(text)-room+1, "…")
			}
			row += text
		}
	}
	return markChrome + DefaultStyles.Faint.Render(ansi.Truncate(row, width, "…"))
}

// renderThought follows the newest line while the thought streams.
func (m ChatModel) renderThought() string {
	header := cmp.Or(thinkingLine(m.transcript.activeText), "thinking")
	width := max(1, m.Renderer.BodyWidth-railWidth)
	return markChrome + DefaultStyles.Faint.Render(ansi.Truncate(header+"…", width, "…"))
}

func (m ChatModel) statusLine() string {
	if m.TurnFailed || m.Notices.HasError() {
		return "Reply failed · see error above"
	}
	if m.Stopping {
		return "stopping…"
	}
	// an idle session says nothing unless verbose: the transcript already
	// ends in the turn's signoff.
	if m.Stopped {
		if m.Flags.Tools {
			return "stopped"
		}
		return ""
	}
	if host := m.reaching(); host != "" {
		return reachingText(host, m.Status.KernelStep)
	}
	// the port owner gave up and forgot the kernel, so nothing reattaches
	if host, _ := daemon.SplitLocation(m.Workspace); host != "" && m.Status.KernelLink == "lost" {
		return "kernel on " + cmp.Or(m.Host, host) + " lost · the next turn starts a fresh one"
	}
	if m.isSending || m.pendingSendCount() > 0 && !m.Status.Running {
		return "preparing"
	}
	if progress := m.latestProgress(); progress != nil {
		if progress.Phase == "generating" {
			return "generating call"
		}
		// the action row above already names what runs
		return "running"
	}
	if m.Status.Running && !m.Status.Idle {
		if m.transcript.activeKind == StreamKindText {
			return "responding"
		}
		if m.Status.Phase != nil {
			switch *m.Status.Phase {
			case daemon.PhaseTool:
				return "running tool"
			case daemon.PhaseCompacting:
				return "compacting context"
			case daemon.PhasePreparing:
				return "preparing"
			}
		}
		return "thinking"
	}
	if m.connecting() {
		return "connecting…"
	}
	if count := m.backgroundJobCount(); count > 0 {
		label := "1 background job running"
		if count > 1 {
			label = fmt.Sprintf("%d background jobs running", count)
		}
		if command := m.agedJobCommand(); command != "" {
			label += " · " + command
		}
		return label
	}
	if m.Flags.Tools {
		return "ready"
	}
	return ""
}

// Phase is optional display metadata, not evidence of an unanswered status.
func (m ChatModel) connecting() bool {
	return m.Status.Phase == nil && !m.Status.Running && !m.Status.Idle
}

// phaseMood is the face class for the phase statusLine names.
func (m ChatModel) phaseMood() mood {
	switch {
	case m.Stopping:
		return moodStopping
	case m.reaching() != "":
		return moodConnecting
	case m.isSending || m.pendingSendCount() > 0 && !m.Status.Running:
		return moodPreparing
	case m.latestProgress() != nil || m.Status.Idle && m.backgroundJobCount() > 0:
		return moodWorking
	case m.transcript.activeKind == StreamKindText:
		return moodResponding
	case m.Status.Phase != nil:
		switch *m.Status.Phase {
		case daemon.PhaseTool:
			return moodWorking
		case daemon.PhaseCompacting:
			return moodCompacting
		case daemon.PhasePreparing:
			return moodPreparing
		}
	}
	return moodThinking
}

// header fits the workspace and the model on one rule without cutting either
// short, shedding the least useful parts first: the middle of the path, the
// brand, the glance counts from the last, then the path down to its name,
// which alone may squeeze the rule to one cell.
func (m ChatModel) header(width int) string {
	host, workspace := daemon.SplitLocation(cmp.Or(m.Workspace, "chat"))
	// a remote workspace's host stays whole in every layout
	lead := ""
	if host == "" {
		workspace = homePath(workspace)
	} else {
		host = cmp.Or(m.Host, host)
		lead = host + ":"
		workspace = scpRelative(underHome(workspace, m.hostHome))
	}
	model := m.Model
	if m.Effort != "" {
		model += ":" + m.Effort
	}
	counts := m.glanceCounts()
	folds := pathFolds(workspace)
	type layout struct {
		place  string
		counts int
		rule   int
		brand  bool
	}
	var layouts []layout
	for _, place := range folds {
		layouts = append(layouts, layout{brand: true, place: place, counts: len(counts), rule: 3})
	}
	for n := len(counts); n >= 0; n-- {
		layouts = append(layouts, layout{brand: false, place: folds[len(folds)-1], counts: n, rule: 3})
	}
	layouts = append(layouts, layout{brand: false, place: filepath.Base(workspace), counts: 0, rule: 1})
	for _, l := range layouts {
		right := strings.Join(append(counts[:l.counts:l.counts], model), "  ")
		left := lead + l.place
		if l.brand {
			left = "✦ " + m.AgentName + " on " + left
		}
		if lipgloss.Width(left)+lipgloss.Width(right)+l.rule+2 > width {
			continue
		}
		place := DefaultStyles.Muted.Render(l.place)
		if host != "" {
			place = m.hostSegment(host) + DefaultStyles.Muted.Render(":"+l.place)
		}
		if l.brand {
			return titleRule(width, brand(m.AgentName)+DefaultStyles.Faint.Render(" on ")+place, DefaultStyles.Faint.Render(right))
		}
		return titleRule(width, place, DefaultStyles.Faint.Render(right))
	}
	return DefaultStyles.Faint.Render(ansi.Truncate(model, width, "…"))
}

// hostSegment is the header's host in its own color once the kernel there is
// attached: faint while it boots or reattaches, the error color once lost.
func (m ChatModel) hostSegment(host string) string {
	switch m.Status.KernelLink {
	case "booting", "reattaching":
		return DefaultStyles.Faint.Render(host)
	case "lost":
		return DefaultStyles.Error.Render(host)
	}
	return hostStyle(host).Render(host)
}

// reaching is the remote host a booting or reattaching kernel is on.
func (m ChatModel) reaching() string {
	host, _ := daemon.SplitLocation(m.Workspace)
	if link := m.Status.KernelLink; host == "" || link != "booting" && link != "reattaching" {
		return ""
	}
	return cmp.Or(m.Host, host)
}

// View draws the chat. The expensive pieces of the frame — the transcript body
// with its glance column, and the input block — are built once per change and
// reused, and a frame nothing changed in returns the string the last one
// returned, so Bubble Tea's own comparison can skip parsing and painting it.
func (m *ChatModel) View() string {
	if m.frame == nil {
		m.frame = &frameCache{}
	}
	width := m.chatWidth()
	pad := strings.Repeat(" ", m.padding())
	rows := m.frame.scratch[:0]
	rows = append(rows, m.header(width), "")
	for _, n := range m.Notices {
		if n.Error {
			rows = append(rows, m.Renderer.errorRow(n.Message))
		} else {
			rows = append(rows, DefaultStyles.Faint.Render(n.Message))
		}
	}
	if len(m.Notices) > 0 {
		rows = append(rows, "")
	}

	rows = append(rows, m.body()...)
	// one row: a job's command may span lines
	status := oneLine(m.statusLine())
	// the face trails the text, so its frames never move anything
	if m.animating() && !m.TurnFailed && !m.Notices.HasError() {
		face := m.phaseMood().frame(m.moodSeed, m.ProgressFrame)
		if host := m.reaching(); host != "" {
			face = connectingFace(host, m.ProgressFrame) // the picker's face for this host
		}
		if m.Width > 0 {
			status = ansi.Truncate(status, max(1, m.chatWidth()-ansi.StringWidth(face)-1), "…")
		}
		status = DefaultStyles.Faint.Render(status) + " " + DefaultStyles.Agent.Render(face)
	}
	if !m.Follow {
		status = fmt.Sprintf("history · %d rows below · pgdn", max(0, m.scrollLimit-m.scrollOffset))
	}
	if m.CopyStatus != "" {
		status = m.CopyStatus
	}
	statusStyle := DefaultStyles.Faint
	if m.TurnFailed || m.Notices.HasError() {
		statusStyle = DefaultStyles.Error
	}
	rows = append(rows, statusStyle.Render(status))
	if len(m.effortOptions) == 0 {
		rows = append(rows, m.chipStrip(width)...)
	}
	rows = append(rows, DefaultStyles.Decor.Render(strings.Repeat("─", width)))
	if len(m.effortOptions) > 0 {
		rows = append(rows, "", DefaultStyles.Bold.Render(ansi.Truncate("Reasoning effort", width, "")), m.effortSelectorView(), DefaultStyles.Faint.Render(ansi.Truncate("← → choose  ·  enter apply  ·  esc cancel", width, "")))
	} else {
		rows = append(rows, m.composer()...)
		if menu := m.CommandMenu.View(m.TextArea.Value()); menu != "" {
			rows = append(rows, strings.Split(strings.TrimSuffix(menu, "\n"), "\n")...)
		}
	}
	rows = append(rows, DefaultStyles.Decor.Render(strings.Repeat("─", width)))
	rows = append(rows, m.renderFooter())
	for i := range rows {
		rows[i] = pad + rows[i]
	}

	m.frame.scratch = rows
	if m.frame.content != "" && sameStrings(rows, m.frame.rows) {
		return m.frame.content
	}
	m.frame.rows = append(m.frame.rows[:0], rows...)
	m.frame.content = stripPrivateMarks(strings.Join(rows, "\n"))
	return m.frame.content
}

// frameCache holds the pieces of a frame whose rendering costs more than
// building the frame around them, each named by every input that shapes it.
// Those inputs are compared by value rather than hashed: a stale screen is
// worse than the microseconds a comparison costs. Everything else in a frame
// (header, status, chips, footer) is cheap enough to build every time, and
// building it means it cannot go stale.
type frameCache struct {
	sidebar      sidebarBlock
	sidebarKey   sidebarKey
	sidebarReady bool

	body      []string
	bodyKey   bodyKey
	bodyReady bool

	composer      []string
	composerKey   composerKey
	composerReady bool

	// rows is the padded frame as last drawn and content the string handed to
	// Bubble Tea, so a frame that changed nothing is not joined again.
	rows    []string
	content string
	// scratch is the row slice the next frame is assembled into.
	scratch []string
}

// sidebarBlock is the glance column: the rows it draws, the glances that did
// not fit the height, and the column as padded for the frame.
type sidebarBlock struct {
	rows    []string
	omitted []PageGlance
	column  []string
}

// forgetComposer drops the cached input block: the textarea's own state moved,
// in a way its value and caret may not show (a selection, the virtual cursor).
func (c *frameCache) forgetComposer() {
	if c != nil {
		c.composerReady = false
	}
}

// sidebarKey names what the glance column is built from. The glances are kept
// as a copy of the fields the column draws: the model's own slice can be
// mutated in place (a job's tone, a row's text), and a key that aliased it
// would compare the change with itself.
type sidebarKey struct {
	glances []PageGlance
	jobs    []PageRow
	width   int
	height  int
}

// same compares a stored key with what the model would build one from now.
func (k sidebarKey) same(glances []PageGlance, jobs []PageRow, width, height int) bool {
	return k.width == width && k.height == height &&
		sameGlances(k.glances, glances) && samePageRows(k.jobs, jobs)
}

// glanceKey copies the glance list down to what the sidebar draws from it.
func glanceKey(glances []PageGlance) []PageGlance {
	key := make([]PageGlance, len(glances))
	for i, g := range glances {
		key[i] = PageGlance{Title: g.Title, Rows: make([]PageRow, len(g.Rows))}
		for j, row := range g.Rows {
			key[i].Rows[j] = PageRow{ID: row.ID, Text: row.Text, Tone: row.Tone}
		}
	}
	return key
}

// bodyKey names what the transcript body is built from: the pane's rows and
// width, and the glance column beside them.
type bodyKey struct {
	rows    []string
	sidebar []string
	width   int
	height  int
}

func (k bodyKey) same(o bodyKey) bool {
	return k.width == o.width && k.height == o.height &&
		sameStrings(k.rows, o.rows) && sameStrings(k.sidebar, o.sidebar)
}

// composerKey names what the input block is drawn from. The textarea and frame
// heights stand in for the prompt height, which walks every line.
type composerKey struct {
	value       string
	placeholder string
	line, col   int
	width       int
	textarea    int
	frame       int
	focused     bool
}

func (k composerKey) same(o composerKey) bool { return k == o }

func sameStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// sameGlances compares two glance lists by what the sidebar draws from them.
func sameGlances(a, b []PageGlance) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].Title != b[i].Title || !samePageRows(a[i].Rows, b[i].Rows) {
			return false
		}
	}
	return true
}

// samePageRows compares sidebar rows by the fields a row is drawn from.
func samePageRows(a, b []PageRow) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].ID != b[i].ID || a[i].Text != b[i].Text || a[i].Tone != b[i].Tone {
			return false
		}
	}
	return true
}

// sidebar is the glance column, rendered again only when what it draws from
// changed: a status poll replaces the glances wholesale, and a frame that only
// moved a row must not re-render the column.
func (c *frameCache) glances(m ChatModel) sidebarBlock {
	width, height := m.sidebarWidth(), m.Viewport.Height()
	jobs := m.jobRows()
	if c.sidebarReady && c.sidebarKey.same(m.Glances, jobs, width, height) {
		return c.sidebar
	}
	var block sidebarBlock
	block.rows, block.omitted = m.buildSidebar()
	block.column = strings.Split(lipgloss.NewStyle().Width(width).Render(strings.Join(block.rows, "\n")), "\n")
	// the key keeps its own copy: the model's glances can change in place, and
	// a key that aliased them would compare a change with itself
	c.sidebarKey = sidebarKey{glances: glanceKey(m.Glances), jobs: jobs, width: width, height: height}
	c.sidebar, c.sidebarReady = block, true
	return block
}

// sidebarColumn is the glance column as the frame draws it: each row padded to
// the sidebar's width, or nothing without one.
func (m ChatModel) sidebarColumn() []string {
	if m.sidebarWidth() <= 0 {
		return nil
	}
	if m.frame != nil {
		return m.frame.glances(m).column
	}
	rows, _ := m.buildSidebar()
	return strings.Split(lipgloss.NewStyle().Width(m.sidebarWidth()).Render(strings.Join(rows, "\n")), "\n")
}

// body is the transcript as the frame draws it: the viewport's rows, padded to
// the pane's width and joined with the glance column.
func (m *ChatModel) body() []string {
	shown := m.Viewport
	if m.History.Len() == 0 && len(m.pendingUsers) == 0 && m.transcript.activeText == "" && m.toolLabel() == "" {
		textWidth := max(1, min(m.Renderer.BodyWidth, m.Viewport.Width())-railWidth)
		shown.rows = nil
		for _, line := range wrapOrChunkLine("What would you like to work on?", textWidth) {
			shown.rows = append(shown.rows, m.Renderer.rail(laneNone)+DefaultStyles.Faint.Render(line))
		}
	}
	column := m.sidebarColumn()
	key := bodyKey{rows: shown.rows, sidebar: column, width: shown.width, height: shown.height}
	if m.dragAnchor == nil && m.frame != nil && m.frame.bodyReady && key.same(m.frame.bodyKey) {
		return m.frame.body
	}
	rows := joinBody(shown.lines(), column, shown.width, m.sidebarWidth())
	if m.dragAnchor != nil {
		// the selection is in transcript rows; the viewport shows from scrollOffset
		anchor, head := *m.dragAnchor, m.dragHead
		anchor.Row, head.Row = anchor.Row-m.scrollOffset, head.Row-m.scrollOffset
		return HighlightSelection(rows, Selection{Anchor: anchor, Head: head, Gutter: railWidth})
	}
	if m.frame != nil {
		m.frame.bodyKey, m.frame.body, m.frame.bodyReady = key, rows, true
	}
	return rows
}

// joinBody pads each transcript row to the pane's width so the glance column
// holds its own, then appends it. This is what lipgloss.JoinHorizontal built by
// parsing both blocks back into styled lines and measuring every row again.
func joinBody(rows, column []string, width, sidebar int) []string {
	out := make([]string, len(rows))
	blank := ""
	if sidebar > 0 {
		blank = "  " + strings.Repeat(" ", sidebar)
	}
	for i, row := range rows {
		if sidebar <= 0 {
			out[i] = row
			continue
		}
		cell := blank
		if i < len(column) {
			cell = "  " + column[i]
		}
		out[i] = row + strings.Repeat(" ", max(0, width-ansi.StringWidth(row))) + cell
	}
	return out
}

// composer is the input block as rows, drawn again only when the textarea's
// state changed. Any message that reaches the textarea forgets it regardless;
// see updateComposer.
func (m *ChatModel) composer() []string {
	ta := m.TextArea
	value := ta.Value()
	placeholder := ""
	if m.waitingForInput() && value == "" {
		placeholder = "ctrl+g editor"
	}
	key := composerKey{value: value, placeholder: placeholder, line: ta.Line(), col: ta.Column(), width: ta.Width(), textarea: ta.Height(), frame: m.Height, focused: ta.Focused()}
	if m.frame != nil && m.frame.composerReady && key.same(m.frame.composerKey) {
		return m.frame.composer
	}
	ta.Placeholder = placeholder
	lines := strings.Split(ta.View(), "\n")
	if height := m.promptHeight(); height < len(lines) {
		lines = lines[:height]
	}
	if m.frame != nil {
		m.frame.composerKey, m.frame.composer, m.frame.composerReady = key, lines, true
	}
	return lines
}

// waitingForInput reports an opened session with no turn in flight, so an
// empty composer reads as the agent's cue rather than a stalled turn.
func (m ChatModel) waitingForInput() bool {
	return !m.connecting() && !m.animating()
}
