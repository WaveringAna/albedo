package tui

import (
	"cmp"
	"fmt"
	"slices"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// modelColumns are the widths every listed row shares, so the effort ladders
// line up.
type modelColumns struct{ name, slots, label, tag int }

func (c modelColumns) cluster() int {
	switch {
	case c.slots == 0:
		return 0
	case c.label == 0:
		return c.slots + 4
	}
	return c.slots + 5 + c.label
}

func (m ModelPickerModel) layout(width int) modelColumns {
	var c modelColumns
	for _, r := range m.rows {
		if r.typed {
			continue
		}
		c.name = max(c.name, ansi.StringWidth(r.model.ID))
		c.slots = max(c.slots, len(effortSteps(r.model.Efforts)))
		for _, level := range r.model.Efforts {
			c.label = max(c.label, ansi.StringWidth(level))
		}
		c.tag = max(c.tag, ansi.StringWidth(m.tag(r)))
	}
	room := width - modelRowPrefix - 1
	if c.tag > 0 {
		room -= c.tag + 2
	}
	// Narrow rows shorten names first, then drop the label, then the ladder.
	longest := c.name
	over := func() bool { return c.name+min(c.cluster(), 1)*2+c.cluster() > room }
	fit := func() { c.name = min(longest, max(min(longest, 16), room-min(c.cluster(), 1)*2-c.cluster())) }
	if over() {
		fit()
	}
	if over() {
		c.label = 0
		fit()
	}
	if over() {
		c.slots = 0
	}
	c.name = max(1, min(c.name, room))
	return c
}

// tag names a listed row's standing: the session's model, or the model the
// profile opens new sessions with.
func (m ModelPickerModel) tag(r modelRow) string {
	switch {
	case r.typed:
		return ""
	case r.profile == m.Profile && r.model.ID == m.Model:
		return "current"
	case r.model.ID == m.catalog(r.profile).settings.Model:
		return "default"
	}
	return ""
}

func (m ModelPickerModel) View() string {
	width, height := cmp.Or(m.Width, 80), cmp.Or(m.Height, 24)
	roomy := height >= 12

	lines := []string{" " + titleRule(width-1, brand("albedo")+" "+DefaultStyles.Muted.Render("/model"), m.selection())}
	if roomy {
		lines = append(lines, "")
	}
	lines = append(lines, " "+promptLead()+m.search.View())
	if height >= 9 {
		lines = append(lines, "")
	}

	paned := width >= 96 && height >= 14
	var tail []string
	if roomy {
		tail = append(tail, "")
	}
	if r, ok := m.highlighted(); ok && !paned && height >= 16 {
		tail = append(tail, " "+m.summary(r))
	}
	tail = append(tail, m.footer(width))
	body := max(1, height-len(lines)-len(tail))

	if paned {
		paneW := min(max(width/3, 34), 48)
		list := m.list(width-paneW-ansi.StringWidth(svSep()), body)
		pane := m.details(paneW, body)
		for i := range body {
			lines = append(lines, list[i]+svSep()+pane[i])
		}
	} else {
		lines = append(lines, m.list(width, body)...)
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

// selection is the session's profile, model and effort for the title.
func (m ModelPickerModel) selection() string {
	model := DefaultStyles.Muted.Render(m.Model)
	if m.Effort != "" {
		model += DefaultStyles.Faint.Render(":" + m.Effort)
	}
	return DefaultStyles.Faint.Render(m.Profile) + DefaultStyles.Decor.Render(" · ") + model
}

// list renders the rows grouped by profile at exactly width × height.
func (m ModelPickerModel) list(width, height int) []string {
	cols := m.layout(width)
	var all []string
	selectedAt := -1
	section := func(label string, count int) {
		if len(all) > 0 && height >= 10 {
			all = append(all, "")
		}
		all = append(all, sectionRule(label, count, width))
	}
	add := func(i int) {
		if i == m.cursor {
			selectedAt = len(all)
		}
		all = append(all, m.row(m.rows[i], i == m.cursor, width, cols))
	}

	i := 0
	for i < len(m.rows) && !m.rows[i].typed {
		start, profile := i, m.rows[i].profile
		for i < len(m.rows) && !m.rows[i].typed && m.rows[i].profile == profile {
			i++
		}
		section(profile, i-start)
		for j := start; j < i; j++ {
			add(j)
		}
		switch c := m.catalog(profile); {
		case c.loading:
			all = append(all, DefaultStyles.Faint.Render("  listing models…"))
		case c.failed:
			all = append(all, DefaultStyles.Faint.Render("  Could not list models. Type a model ID to continue."))
		}
	}
	if i < len(m.rows) {
		section("as typed", len(m.rows)-i)
		for ; i < len(m.rows); i++ {
			add(i)
		}
	}
	if len(m.rows) == 0 {
		all = append(all, DefaultStyles.Faint.Render("  no models match"))
	}
	return scrollWindow(all, selectedAt, width, height)
}

func (m ModelPickerModel) row(r modelRow, selected bool, width int, cols modelColumns) string {
	bar, nameStyle := " ", lipgloss.NewStyle()
	if selected {
		bar, nameStyle = selectBar(), DefaultStyles.Bold
	}
	line := bar + " "
	if r.typed {
		line += nameStyle.Render(ansi.Truncate(r.model.ID, max(1, width/2), "…")) + DefaultStyles.Faint.Render("  on "+r.profile)
	} else {
		line += markedCell(r.model.ID, r.hits, cols.name, nameStyle)
		if cols.cluster() > 0 {
			line += "  " + m.ladder(r, selected, cols)
		}
		if tag := m.tag(r); tag != "" {
			style := DefaultStyles.Faint
			if tag == "current" {
				style = DefaultStyles.Success
			}
			line += strings.Repeat(" ", max(2, width-ansi.StringWidth(line)-ansi.StringWidth(tag)-1)) + style.Render(tag)
		}
	}
	if selected {
		return selectedLine(line, width)
	}
	return line
}

// markedCell fits s to width like svCell and draws the characters at hits in
// the prompt color, so a search shows what it matched.
func markedCell(s string, hits []int, width int, base lipgloss.Style) string {
	if width <= 0 {
		return ""
	}
	plain := ansi.Truncate(s, width, "…")
	kept := len(plain)
	if plain != s {
		kept -= len("…")
	}
	hit := DefaultStyles.Prompt.Inherit(base)
	var b strings.Builder
	run, marked := "", false
	flush := func() {
		if run != "" {
			style := base
			if marked {
				style = hit
			}
			b.WriteString(style.Render(run))
		}
	}
	for i, r := range plain {
		if m := i < kept && slices.Contains(hits, i); m != marked {
			flush()
			run, marked = "", m
		}
		run += string(r)
	}
	flush()
	return b.String() + strings.Repeat(" ", max(0, width-ansi.StringWidth(plain)))
}

// ladder draws a row's effort as squares filling toward the highest level,
// with arrows on the selected row where there is a level to step to.
func (m ModelPickerModel) ladder(r modelRow, selected bool, cols modelColumns) string {
	levels := r.model.Efforts
	if len(levels) == 0 {
		return strings.Repeat(" ", cols.cluster())
	}
	effort := m.effort(r)
	steps := effortSteps(levels)
	filled := slices.Index(steps, effort) + 1
	var squares strings.Builder
	for i := range cols.slots {
		switch {
		case i >= len(steps):
			squares.WriteByte(' ')
		case i >= filled:
			squares.WriteString(DefaultStyles.Decor.Render("▱"))
		case selected:
			squares.WriteString(brandInk(float64(i) / float64(max(1, len(steps)-1))).Render("▰"))
		default:
			squares.WriteString(DefaultStyles.Muted.Render("▰"))
		}
	}
	arrow := func(glyph string, open bool) string {
		if !selected {
			return " "
		}
		if open {
			return DefaultStyles.Muted.Render(glyph)
		}
		return DefaultStyles.Decor.Render(glyph)
	}
	at := slices.Index(levels, effort)
	out := arrow("‹", at > 0) + " " + squares.String() + " " + arrow("›", at < len(levels)-1)
	if cols.label > 0 {
		label := DefaultStyles.Faint
		if selected {
			label = lipgloss.NewStyle()
		}
		out += " " + label.Render(svCell(effort, cols.label, false))
	}
	return out
}

// facts are what the catalog knows about a row's model, as label and value.
func (m ModelPickerModel) facts(r modelRow) [][2]string {
	var facts [][2]string
	if r.model.Context > 0 {
		facts = append(facts, [2]string{"context", compactTokens(m.window(r)) + " tokens"})
	}
	if raisable(r.model) {
		state := DefaultStyles.Faint.Render("default") + DefaultStyles.Decor.Render(" · ") +
			DefaultStyles.Faint.Render("tab raises to "+compactTokens(r.model.MaxContext))
		if m.raised(r) {
			state = brandInk(1).Bold(true).Render("raised") + DefaultStyles.Decor.Render(" · ") +
				DefaultStyles.Faint.Render("tab restores "+compactTokens(r.model.Context))
		}
		facts = append(facts, [2]string{"cap", state})
	}
	if r.model.Output > 0 {
		facts = append(facts, [2]string{"output", compactTokens(r.model.Output) + " tokens"})
	}
	if len(r.model.Input) > 0 {
		facts = append(facts, [2]string{"input", strings.Join(r.model.Input, ", ")})
	}
	return facts
}

// compactTokens writes a token count as 8k, 400k or 1.05m.
func compactTokens(n int) string {
	switch {
	case n >= 1_000_000:
		return strings.TrimSuffix(strings.TrimRight(fmt.Sprintf("%.2f", float64(n)/1e6), "0"), ".") + "m"
	case n >= 1000:
		return fmt.Sprintf("%dk", n/1000)
	}
	return fmt.Sprint(n)
}

// summary is the highlighted row's facts on one line, for narrow screens.
func (m ModelPickerModel) summary(r modelRow) string {
	if r.typed {
		return DefaultStyles.Faint.Render("sent to " + r.profile + " as typed")
	}
	var parts []string
	if r.model.Context > 0 {
		parts = append(parts, compactTokens(m.window(r))+" context")
	}
	if raisable(r.model) && m.raised(r) {
		parts = append(parts, "cap raised")
	}
	if r.model.Output > 0 {
		parts = append(parts, compactTokens(r.model.Output)+" output")
	}
	if len(r.model.Input) > 0 {
		parts = append(parts, strings.Join(r.model.Input, ", "))
	}
	if effort := m.effort(r); effort != "" {
		parts = append(parts, effort+" effort")
	}
	return DefaultStyles.Faint.Render(strings.Join(parts, " · "))
}

// details renders the highlighted row's pane at exactly width × height.
func (m ModelPickerModel) details(width, height int) []string {
	inner := max(1, width-2)
	r, ok := m.highlighted()
	if !ok {
		return paneBox([]string{"", DefaultStyles.Muted.Render("nothing matches"), DefaultStyles.Faint.Render("Type a model ID to use it as entered")}, inner, width, height)
	}
	var lines []string
	for _, l := range svWrap(r.model.ID, inner, 2) {
		lines = append(lines, DefaultStyles.Bold.Render(l))
	}
	meta := []string{DefaultStyles.Muted.Render(r.profile)}
	if protocol := m.catalog(r.profile).settings.Protocol; protocol != "" {
		meta = append(meta, DefaultStyles.Faint.Render(protocol))
	}
	if tag := m.tag(r); tag != "" {
		style := DefaultStyles.Faint
		if tag == "current" {
			style = DefaultStyles.Success
		}
		meta = append(meta, style.Render(tag))
	}
	lines = append(lines, strings.Join(meta, DefaultStyles.Decor.Render(" · ")), DefaultStyles.Decor.Render(strings.Repeat("─", inner)))

	note := func(text string) {
		for _, l := range svWrap(text, inner, 3) {
			lines = append(lines, DefaultStyles.Faint.Render(l))
		}
	}
	if r.typed {
		note(r.profile + " does not list this id, so it is sent as typed and the daemon picks the effort.")
	} else {
		facts := m.facts(r)
		if levels := r.model.Efforts; len(levels) > 0 {
			chosen := m.effort(r)
			marks := make([]string, len(levels))
			for i, level := range levels {
				marks[i] = DefaultStyles.Faint.Render(level)
				if level == chosen {
					marks[i] = brandInk(1).Bold(true).Render(level)
				}
			}
			facts = append(facts, [2]string{"effort", strings.Join(marks, DefaultStyles.Decor.Render(" · "))})
		}
		for _, f := range facts {
			lines = append(lines, DefaultStyles.Muted.Render(svCell(f[0], 9, false))+f[1])
		}
		if len(facts) == 0 {
			note("the catalog knows nothing else about this model.")
		}
	}
	lines = append(lines, "")
	note("enter switches this session and makes it the default for new sessions.")
	return paneBox(lines, inner, width, height)
}

func (m ModelPickerModel) footer(width int) string {
	hints := []hint{{"↑↓", "move"}, {"←→", "effort"}}
	if r, ok := m.highlighted(); ok && raisable(r.model) {
		hints = append(hints, hint{"tab", "cap"})
	}
	left := " " + keyHints(append(hints, hint{"enter", "switch"}, hint{"esc", "back"})...)
	loading, models := 0, 0
	for _, c := range m.catalogs {
		if c.loading {
			loading++
		}
		models += len(c.models)
	}
	var right string
	switch {
	case m.Saving:
		right = DefaultStyles.Busy.Render("switching…")
	case m.Error != "":
		right = DefaultStyles.Error.Render(m.Error)
	case loading > 0:
		right = DefaultStyles.Faint.Render(fmt.Sprintf("%d of %d profiles listed…", len(m.catalogs)-loading, len(m.catalogs)))
	default:
		right = DefaultStyles.Faint.Render(counted(models, "model")) + DefaultStyles.Decor.Render(" · ") +
			DefaultStyles.Faint.Render(counted(len(m.catalogs), "profile"))
	}
	gap := width - ansi.StringWidth(left) - ansi.StringWidth(right) - 1
	if gap >= 3 {
		return left + strings.Repeat(" ", gap) + right
	}
	if m.Error != "" {
		return " " + right
	}
	return left
}

func counted(n int, noun string) string {
	if n == 1 {
		return "1 " + noun
	}
	return fmt.Sprintf("%d %ss", n, noun)
}
