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
		rate = fmt.Sprintf(" · %.1f tok/s", *u.TokensPerSecond)
	}
	return formatTokens(total) + " tokens" + rate
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

func (m ChatModel) sidebarWidth() int {
	for _, glance := range m.Glances {
		if len(glance.Rows) > 0 {
			margin := m.chatWidth() - min(100, m.chatWidth()) - 2
			if margin >= 16 {
				return min(32, margin)
			}
			break
		}
	}
	return 0
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
	}
	return "running " + progress.Name
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
	return markChrome + m.Styles.Faint.Render(ansi.Truncate(row, width, "…"))
}

// renderThought follows the newest line while the thought streams.
func (m ChatModel) renderThought() string {
	header := cmp.Or(thinkingLine(m.transcript.activeText), "thinking")
	width := max(1, m.Renderer.BodyWidth-railWidth)
	return markChrome + m.Styles.Faint.Render(ansi.Truncate(header+"…", width, "…"))
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
		return "running " + progress.Name
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
	case m.latestProgress() != nil:
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
		place := m.Styles.Muted.Render(l.place)
		if host != "" {
			place = m.hostSegment(host) + m.Styles.Muted.Render(":"+l.place)
		}
		if l.brand {
			return titleRule(width, brand(m.AgentName)+m.Styles.Faint.Render(" on ")+place, m.Styles.Faint.Render(right))
		}
		return titleRule(width, place, m.Styles.Faint.Render(right))
	}
	return m.Styles.Faint.Render(ansi.Truncate(model, width, "…"))
}

// hostSegment is the header's host in its own color once the kernel there is
// attached: faint while it boots or reattaches, the error color once lost.
func (m ChatModel) hostSegment(host string) string {
	switch m.Status.KernelLink {
	case "booting", "reattaching":
		return m.Styles.Faint.Render(host)
	case "lost":
		return m.Styles.Error.Render(host)
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

func (m ChatModel) View() string {
	width := m.chatWidth()
	pad := strings.Repeat(" ", m.padding())
	var rows []string
	rows = append(rows, m.header(width), "")
	for _, n := range m.Notices {
		if n.Error {
			rows = append(rows, m.Renderer.errorRow(n.Message))
		} else {
			rows = append(rows, m.Styles.Faint.Render(n.Message))
		}
	}
	if len(m.Notices) > 0 {
		rows = append(rows, "")
	}

	view := m.Viewport.View()
	if m.History.Len() == 0 && len(m.pendingUsers) == 0 && m.transcript.activeText == "" && m.toolLabel() == "" {
		textWidth := max(1, min(m.Renderer.BodyWidth, m.Viewport.Width())-railWidth)
		var emptyRows []string
		for _, line := range wrapOrChunkLine("What would you like to work on?", textWidth) {
			emptyRows = append(emptyRows, m.Renderer.rail(laneNone)+m.Styles.Faint.Render(line))
		}
		view = strings.Join(emptyRows, "\n")
	}
	if m.sidebarWidth() > 0 {
		view = lipgloss.JoinHorizontal(lipgloss.Top, view, "  ", m.renderGlances())
	}
	content := strings.Split(view, "\n")
	for len(content) < m.Viewport.Height() {
		content = append(content, "")
	}
	content = content[:min(len(content), m.Viewport.Height())]
	if m.dragAnchor != nil {
		// the selection is in transcript rows; the viewport shows from scrollOffset
		anchor, head := *m.dragAnchor, m.dragHead
		anchor.Row, head.Row = anchor.Row-m.scrollOffset, head.Row-m.scrollOffset
		content = HighlightSelection(content, Selection{Anchor: anchor, Head: head, Gutter: railWidth})
	}
	rows = append(rows, content...)
	status := m.statusLine()
	// the face trails the text, so its frames never move anything
	if m.animating() && !m.TurnFailed && !m.Notices.HasError() {
		face := m.phaseMood().frame(m.moodSeed, m.ProgressFrame)
		if host := m.reaching(); host != "" {
			face = connectingFace(host, m.ProgressFrame) // the picker's face for this host
		}
		status = m.Styles.Faint.Render(status) + " " + m.Styles.Agent.Render(face)
	}
	if !m.Follow {
		status = fmt.Sprintf("history · %d rows below · pgdn", max(0, m.scrollLimit-m.scrollOffset))
	}
	if m.AttachedImage != nil {
		status = daemon.ImageLabel(m.AttachedImage.ImageMetadata) + " attached · esc remove"
	}
	if m.CopyStatus != "" {
		status = m.CopyStatus
	}
	statusStyle := m.Styles.Faint
	if m.TurnFailed || m.Notices.HasError() {
		statusStyle = m.Styles.Error
	}
	rows = append(rows, statusStyle.Render(status))
	rows = append(rows, m.Styles.Decor.Render(strings.Repeat("─", width)))
	if len(m.effortOptions) > 0 {
		rows = append(rows, "", m.Styles.Bold.Render(ansi.Truncate("Reasoning effort", width, "")), m.effortSelectorView(), m.Styles.Faint.Render(ansi.Truncate("← → choose  ·  enter apply  ·  esc cancel", width, "")))
	} else {
		rows = append(rows, strings.Split(strings.TrimSuffix(m.composerView(), "\n"), "\n")...)
		if menu := m.CommandMenu.View(m.TextArea.Value()); menu != "" {
			rows = append(rows, strings.Split(strings.TrimSuffix(menu, "\n"), "\n")...)
		}
	}
	rows = append(rows, m.Styles.Decor.Render(strings.Repeat("─", width)))
	rows = append(rows, m.renderFooter())
	for i, row := range rows {
		rows[i] = pad + row
	}
	return strings.Join(rows, "\n")
}

func (m ChatModel) composerView() string {
	ta := m.TextArea
	if m.waitingForInput() && ta.Value() == "" {
		ta.Placeholder = "ctrl+g editor"
	} else {
		ta.Placeholder = ""
	}
	lines := strings.Split(ta.View(), "\n")
	h := m.promptHeight()
	if h < len(lines) {
		lines = lines[:h]
	}
	return strings.Join(lines, "\n")
}

// waitingForInput reports an opened session with no turn in flight, so an
// empty composer reads as the agent's cue rather than a stalled turn.
func (m ChatModel) waitingForInput() bool {
	return !m.connecting() && !m.animating()
}
