package tui

import (
	"fmt"
	"maps"
	"slices"
	"strings"

	"github.com/charmbracelet/x/ansi"
)

func (m AgentsViewModel) paneHeader() []string {
	// One column goes to the space after the divider.
	width := m.paneWidth() - 1
	rows := make([]string, 0, 12)
	n := m.nodes[m.selected]
	if n == nil || width <= 0 {
		return rows
	}
	colors := agentColors()
	styled := func(hue rgb, s string) string { return sgr(hue.hex(), "") + s + ansiReset }
	state := "idle"
	switch {
	case n.id == agentsYou:
		state = "that's you"
	case n.running:
		state = "running"
	case n.closed:
		state = "closed"
	case n.peer:
		state = "outside this tree"
	}
	rows = append(rows, styled(n.hue, "● ")+DefaultStyles.Bold.Render(n.name)+"  "+DefaultStyles.Faint.Render(state))
	var meta []string
	if n.model != "" {
		meta = append(meta, n.model)
	}
	if n.id != agentsYou {
		meta = append(meta, fmt.Sprintf("depth %d", n.depth))
	}
	if parent := m.nodes[n.parent]; parent != nil {
		meta = append(meta, "parent "+parent.name)
	}
	rows = append(rows, DefaultStyles.Faint.Render(ansi.Truncate(strings.Join(meta, " · "), width, "…")), "")
	if len(n.mail) > 0 {
		rows = append(rows, DefaultStyles.Muted.Render("mail"))
		for _, mail := range n.mail[max(0, len(n.mail)-5):] {
			var arrow string
			if mail.incoming {
				arrow = styled(colors.mail, "← ")
			} else {
				arrow = DefaultStyles.Faint.Render("→ ")
			}
			rows = append(rows, ansi.Truncate(arrow+mail.who+" "+DefaultStyles.Faint.Render(mail.kind), width, "…"))
		}
		rows = append(rows, "")
	}
	live := DefaultStyles.Muted.Render("tail")
	if n.running {
		live += " " + styled(n.hue, "●") + DefaultStyles.Faint.Render(" live")
	}
	if n.tail.omitted || n.preview.omitted {
		live += DefaultStyles.Faint.Render(" · earlier output omitted")
	}
	return append(rows, live)
}

func (m AgentsViewModel) pane(height int) []string {
	rows := m.paneHeader()
	room := max(0, height-len(rows))
	if room == 0 || len(rows) == 0 {
		return rows
	}
	wrapped := m.tailCache.rows
	if len(wrapped) == 0 {
		return append(rows, DefaultStyles.Faint.Render("nothing yet"))
	}
	return append(rows, wrapped[max(0, len(wrapped)-room):]...)
}

// drawTail wraps one tail line to width and styles it by kind.
func drawTail(line tailLine, width, limit int) []string {
	gutter, inner := "", width
	format := func(s ...string) string { return strings.Join(s, "") }
	switch line.kind {
	case tailThinking:
		format = func(s ...string) string { return DefaultStyles.Faint.Render(ansiItalic + s[0]) }
	case tailCode:
		gutter, inner, format = DefaultStyles.Decor.Render("│ "), width-2, DefaultStyles.Muted.Render
	case tailOutput:
		gutter, inner, format = DefaultStyles.Decor.Render("⎿ "), width-2, DefaultStyles.Faint.Render
	case tailMeta:
		format = DefaultStyles.Faint.Render
	}
	wrapped := ansi.Hardwrap(line.text, max(8, inner), true)
	start := len(wrapped)
	for range limit {
		index := strings.LastIndexByte(wrapped[:start], '\n')
		if index < 0 {
			start = 0
			break
		}
		start = index
	}
	if start > 0 {
		start++
	}
	var out []string
	for part := range strings.SplitSeq(wrapped[start:], "\n") {
		// A cached row must not retain the rest of a long wrapped line.
		out = append(out, gutter+format(strings.Clone(part)))
	}
	return out
}

func (m AgentsViewModel) View() string {
	if m.Width <= 0 || m.Height <= 0 {
		return ""
	}
	live, tokens := 0, 0
	for id, n := range m.nodes {
		if id == agentsYou {
			continue
		}
		if n.running {
			live++
		}
		tokens += n.chars / 4
	}
	right := DefaultStyles.Faint.Render(fmt.Sprintf("%d agents · %d running · ▴%s tok", len(m.nodes)-1, live, compactCount(tokens)))
	out := []string{titleRule(m.Width, brand("albedo")+" "+DefaultStyles.Muted.Render("/agents"), right)}

	var confirmRows []string
	if m.confirm != "" {
		what := m.label(m.confirm, "")
		if below := m.below(m.confirm); below == 1 {
			what += " and the agent below it"
		} else if below > 1 {
			what += fmt.Sprintf(" and the %d agents below it", below)
		}
		for line := range strings.SplitSeq(ansi.Wrap("Their transcripts and work will also be deleted. Delete "+what+"?", max(1, m.Width), " "), "\n") {
			confirmRows = append(confirmRows, DefaultStyles.Warning.Render(line))
		}
		confirmRows = append(confirmRows, keyHints(hint{"y", "delete"}, hint{"any key", "keep"}))
	}
	bodyH := max(1, m.Height-3-max(1, len(confirmRows)))
	dagW := m.dagWidth()
	// Scroll so the selected dot stays in view on a tall swarm.
	offset := 0
	if n := m.nodes[m.selected]; n != nil && n.y+3 > bodyH {
		offset = n.y + 3 - bodyH
	}
	canvas := newCanvas(dagW, bodyH+offset)
	m.drawEdges(canvas)
	m.drawNodes(canvas)
	pane := m.pane(bodyH)
	divider := DefaultStyles.Decor.Render("│")
	pw := m.paneWidth()
	for y := range bodyH {
		row := canvas.line(y + offset)
		if pw > 0 {
			side := ""
			if y < len(pane) {
				side = pane[y]
			}
			row += divider + " " + ansi.Truncate(side, pw-1, "…")
		}
		out = append(out, row)
	}

	status := ""
	switch {
	case m.rename.active():
		status = DefaultStyles.Muted.Render("rename ") + DefaultStyles.Bold.Render(m.label(m.rename.id, ""))
		if n := m.nodes[m.rename.id]; n != nil && n.address != "" {
			status += DefaultStyles.Faint.Render(" · its family can still mail it at ") + DefaultStyles.Muted.Render(n.address)
		}
	case m.err != nil:
		status = DefaultStyles.Error.Render(m.err.Error() + " · ctrl+l retries")
	case len(m.pendingOperations) > 0:
		ids := slices.Sorted(maps.Keys(m.pendingOperations))
		status = DefaultStyles.Error.Render("Unresolved request: " + strings.Join(ids, ", "))
	case m.noticeT > 0:
		status = DefaultStyles.Muted.Render(m.notice)
	}
	if len(confirmRows) > 0 {
		out = append(out, confirmRows...)
	} else {
		out = append(out, status)
	}
	target := m.label(m.selected, "agent")
	input := m.input.View()
	if m.input.Value() == "" {
		input = DefaultStyles.Faint.Render("message " + target + "…  or /spawn <name> <task>")
	}
	if n := m.nodes[m.rename.id]; n != nil && m.rename.active() {
		out = append(out, DefaultStyles.Prompt.Render("✎ ")+m.rename.view(m.Width-promptMarkWidth), renameHints("restores "+renameBlank(n)))
	} else {
		out = append(out, promptLead()+input, keyHints(hint{"tab", "next agent"}, hint{"enter", "open or send"}, hint{"ctrl+r", "rename"}, hint{"ctrl+x", "delete"}, hint{"esc", "back"}))
	}
	return strings.Join(out, "\n")
}
