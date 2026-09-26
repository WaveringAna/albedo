package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"errors"
	"fmt"
	"maps"
	"slices"
	"strings"
	"unicode"

	"github.com/charmbracelet/bubbles/cursor"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/sahilm/fuzzy"
)

// The /model picker lists every saved profile's models at once, grouped by
// profile, and lets each row carry a reasoning effort before you switch.

type ModelPickerSelectMsg struct {
	Model    string
	Provider string
	// Effort is the chosen reasoning level. Empty lets the daemon choose.
	Effort string
}

type ModelPickerCancelMsg struct{}

type modelCatalogLoadedMsg struct {
	Profile string
	Models  []daemon.Model
	Err     error
}

// profileCatalog is one profile's models: the ones the session and the
// profile already use, then whatever the daemon lists.
type profileCatalog struct {
	name     string
	settings config.Settings
	loading  bool
	failed   bool
	models   []daemon.Model
}

// modelRow is a row you can pick: a profile's model, or the search text sent
// to a profile as a model id.
type modelRow struct {
	profile string
	model   daemon.Model
	typed   bool
	// hits are the byte offsets of the id's characters the search matched.
	hits []int
}

func (r modelRow) key() string {
	if r.typed {
		return "typed\x00" + r.profile
	}
	return r.profile + "\x00" + r.model.ID
}

type ModelPickerModel struct {
	Conn *daemon.Connection
	// The session's selection when the picker opened.
	Profile, Model, Effort string
	Saving                 bool
	Error                  string
	Width, Height          int

	catalogs []profileCatalog
	rows     []modelRow
	cursor   int
	// browsing is set once you move through the list, so arrows change the
	// effort even while a search is typed.
	browsing bool
	efforts  map[string]string
	search   textinput.Model
}

func NewModelPickerModel(conn *daemon.Connection, profiles config.Profiles, model, profile, effort string) ModelPickerModel {
	if profile == "" {
		profile = profiles.Active
	}
	lead := func(name string) int {
		if name == profile {
			return 0
		}
		return 1
	}
	names := slices.Sorted(maps.Keys(profiles.Providers))
	slices.SortStableFunc(names, func(a, b string) int { return cmp.Compare(lead(a), lead(b)) })

	catalogs := make([]profileCatalog, 0, len(names))
	for _, name := range names {
		settings := profiles.Providers[name]
		seeds := []string{settings.Model}
		if name == profile {
			seeds = []string{model, settings.Model}
		}
		catalogs = append(catalogs, profileCatalog{
			name:     name,
			settings: settings,
			loading:  true,
			models:   mergeModels(seeds, nil),
		})
	}

	search := textinput.New()
	search.Prompt = ""
	search.Placeholder = "search models, or type an id"
	search.PlaceholderStyle = DefaultStyles.Faint
	search.Cursor.Style = DefaultStyles.Cursor
	search.Cursor.SetMode(cursor.CursorStatic)
	search.Focus()

	m := ModelPickerModel{
		Conn:     conn,
		Profile:  profile,
		Model:    model,
		Effort:   effort,
		catalogs: catalogs,
		efforts:  map[string]string{},
		search:   search,
	}
	m.refilter(true)
	current := modelRow{profile: profile, model: daemon.Model{ID: model}}.key()
	m.cursor = max(0, slices.IndexFunc(m.rows, func(r modelRow) bool { return r.key() == current }))
	return m
}

// mergeModels lists seeds first, then the rest of listed, each id once. A
// listed entry lends its catalog facts to the seed of the same id.
func mergeModels(seeds []string, listed []daemon.Model) []daemon.Model {
	byID := make(map[string]daemon.Model, len(listed))
	for _, m := range listed {
		byID[m.ID] = m
	}
	seen := map[string]bool{"": true}
	var out []daemon.Model
	for _, id := range seeds {
		if !seen[id] {
			seen[id] = true
			model, ok := byID[id]
			if !ok {
				model = daemon.Model{ID: id}
			}
			out = append(out, model)
		}
	}
	for _, m := range listed {
		if !seen[m.ID] {
			seen[m.ID] = true
			out = append(out, m)
		}
	}
	return out
}

func (m *ModelPickerModel) SetSize(width, height int) {
	m.Width = width
	m.Height = height
	m.search.Width = max(1, width-6)
}

func (m ModelPickerModel) Init() tea.Cmd {
	cmds := []tea.Cmd{textinput.Blink}
	for _, c := range m.catalogs {
		cmds = append(cmds, m.listCmd(c))
	}
	return tea.Batch(cmds...)
}

func (m ModelPickerModel) listCmd(c profileCatalog) tea.Cmd {
	conn := m.Conn
	return func() tea.Msg {
		if conn == nil {
			return modelCatalogLoadedMsg{Profile: c.name, Err: errors.New("daemon connection unavailable")}
		}
		extension, endpoint := cmp.Or(c.settings.Extension, "openai"), c.settings.BaseURL
		if extension == "codex" {
			endpoint = ""
		}
		models, err := daemon.ListModels(context.Background(), conn, extension, endpoint)
		return modelCatalogLoadedMsg{Profile: c.name, Models: models, Err: err}
	}
}

func validateModelID(m string) error {
	m = strings.TrimSpace(m)
	if m == "" || jsLength(m) > 512 {
		return errors.New("enter a model id of 1–512 characters")
	}
	for _, r := range m {
		if r < 0x20 || r == 0x7f {
			return errors.New("enter a model id of 1–512 characters")
		}
	}
	return nil
}

// searchKey folds case and separators, so "gpt.5" finds "gpt-5.1".
const searchSeparators = " -_.:/"

var searchNoise = strings.NewReplacer(" ", "", "-", "", "_", "", ".", "", ":", "", "/", "")

func searchKey(s string) string { return searchNoise.Replace(strings.ToLower(s)) }

// matchRank orders search matches, compared element by element: an exact id
// first, then words that start the id or one of its parts, then the fuzzy
// score. A fuzzy bonus never outweighs a word typed from the start.
type matchRank [3]int

func (a matchRank) compare(b matchRank) int { return slices.Compare(a[:], b[:]) }

// matchModel ranks a model against the search words. Each word must fuzzy
// match the model id or the profile name.
func matchModel(words []string, profile, id string) (rank matchRank, hits []int, ok bool) {
	if whole := strings.Join(words, ""); whole != "" && (whole == searchKey(id) || whole == searchKey(profile+id)) {
		rank[0] = 1
	}
	fields := []string{id, profile}
	for _, word := range words {
		var best matchRank
		var bestHits []int
		found := fuzzy.Find(word, fields)
		for i, f := range found {
			if r := (matchRank{0, startTier(fields[f.Index], word), f.Score}); i == 0 || r.compare(best) > 0 {
				best, bestHits = r, nil
				if f.Index == 0 {
					bestHits = f.MatchedIndexes
				}
			}
		}
		if len(found) == 0 {
			return matchRank{}, nil, false
		}
		rank[1] += best[1]
		rank[2] += best[2]
		hits = append(hits, bestHits...)
	}
	return rank, hits, true
}

// startTier is 2 when word starts s, 1 when it starts a part of s after a
// separator, else 0. Separators fold as in searchKey, so "gpt5" starts "gpt-5".
func startTier(s, word string) int {
	if strings.HasPrefix(searchKey(s), word) {
		return 2
	}
	for i := 1; i < len(s); i++ {
		if strings.ContainsRune(searchSeparators, rune(s[i-1])) && strings.HasPrefix(searchKey(s[i:]), word) {
			return 1
		}
	}
	return 0
}

// refilter rebuilds the rows from the catalogs and the search text. The
// cursor stays on its row unless reset.
func (m *ModelPickerModel) refilter(reset bool) {
	keep := ""
	if r, ok := m.highlighted(); ok && !reset {
		keep = r.key()
	}
	query := strings.TrimSpace(m.search.Value())
	var words []string
	for _, field := range strings.Fields(query) {
		if word := searchKey(field); word != "" {
			words = append(words, word)
		}
	}

	// Rows rank within their profile, and profiles by their best
	// row. Ties, and an empty search, keep the catalog order.
	type scored struct {
		row  modelRow
		rank matchRank
	}
	var groups [][]scored
	var typed []modelRow
	for _, c := range m.catalogs {
		var group []scored
		for _, model := range c.models {
			if rank, hits, ok := matchModel(words, c.name, model.ID); ok {
				group = append(group, scored{modelRow{profile: c.name, model: model, hits: hits}, rank})
			}
		}
		if len(group) > 0 {
			slices.SortStableFunc(group, func(a, b scored) int { return b.rank.compare(a.rank) })
			groups = append(groups, group)
		}
		// An id has no spaces, so a search of several words offers none.
		listed := slices.ContainsFunc(c.models, func(model daemon.Model) bool { return model.ID == query })
		if !listed && query != "" && !strings.ContainsFunc(query, unicode.IsSpace) && validateModelID(query) == nil {
			typed = append(typed, modelRow{profile: c.name, model: daemon.Model{ID: query}, typed: true})
		}
	}
	slices.SortStableFunc(groups, func(a, b []scored) int { return b[0].rank.compare(a[0].rank) })
	m.rows = nil
	for _, group := range groups {
		for _, s := range group {
			m.rows = append(m.rows, s.row)
		}
	}
	m.rows = append(m.rows, typed...)
	m.cursor = max(0, slices.IndexFunc(m.rows, func(r modelRow) bool { return r.key() == keep }))
}

func (m ModelPickerModel) highlighted() (modelRow, bool) {
	if m.cursor < 0 || m.cursor >= len(m.rows) {
		return modelRow{}, false
	}
	return m.rows[m.cursor], true
}

func (m ModelPickerModel) catalog(profile string) profileCatalog {
	i := slices.IndexFunc(m.catalogs, func(c profileCatalog) bool { return c.name == profile })
	if i < 0 {
		return profileCatalog{}
	}
	return m.catalogs[i]
}

// effort is the level a row would switch with: your pick, else the session's
// level when the model has it, else the daemon's default.
func (m ModelPickerModel) effort(r modelRow) string {
	levels := r.model.Efforts
	switch {
	case len(levels) == 0:
		return ""
	case slices.Contains(levels, m.efforts[r.key()]):
		return m.efforts[r.key()]
	case slices.Contains(levels, m.Effort):
		return m.Effort
	}
	return defaultEffort(levels)
}

// defaultEffort mirrors the daemon: medium, else the first of high, xhigh or
// max, else the highest level.
func defaultEffort(levels []string) string {
	if slices.Contains(levels, "medium") {
		return "medium"
	}
	if i := slices.IndexFunc(levels, func(l string) bool { return l == "high" || l == "xhigh" || l == "max" }); i >= 0 {
		return levels[i]
	}
	return levels[len(levels)-1]
}

// effortSteps are the levels that fill a square. None and off fill nothing.
func effortSteps(levels []string) []string {
	return slices.DeleteFunc(slices.Clone(levels), func(l string) bool { return l == "none" || l == "off" })
}

// stepEffort moves the highlighted row's effort one level, stopping at the
// ends. It reports whether the row has levels to step through.
func (m *ModelPickerModel) stepEffort(by int) bool {
	r, ok := m.highlighted()
	if !ok || len(r.model.Efforts) == 0 {
		return false
	}
	levels := r.model.Efforts
	i := slices.Index(levels, m.effort(r)) + by
	m.efforts[r.key()] = levels[min(max(i, 0), len(levels)-1)]
	return true
}

func (m *ModelPickerModel) move(by int) {
	if len(m.rows) > 0 {
		m.cursor = min(max(m.cursor+by, 0), len(m.rows)-1)
		m.browsing = true
	}
}

func (m ModelPickerModel) Update(msg tea.Msg) (ModelPickerModel, tea.Cmd) {
	switch msg := msg.(type) {
	case modelCatalogLoadedMsg:
		i := slices.IndexFunc(m.catalogs, func(c profileCatalog) bool { return c.name == msg.Profile })
		if i < 0 {
			return m, nil
		}
		m.catalogs = slices.Clone(m.catalogs)
		c := &m.catalogs[i]
		c.loading, c.failed = false, msg.Err != nil
		seeds := make([]string, len(c.models))
		for j, model := range c.models {
			seeds[j] = model.ID
		}
		c.models = mergeModels(seeds, msg.Models)
		m.refilter(false)
		return m, nil

	case tea.KeyMsg:
		if m.Saving {
			return m, nil
		}
		switch msg.Type {
		case tea.KeyEsc, tea.KeyCtrlC, tea.KeyCtrlD:
			return m, func() tea.Msg { return ModelPickerCancelMsg{} }
		case tea.KeyEnter:
			r, ok := m.highlighted()
			if !ok {
				return m, nil
			}
			if err := validateModelID(r.model.ID); err != nil {
				m.Error = err.Error()
				return m, nil
			}
			m.Error = ""
			choice := ModelPickerSelectMsg{Model: r.model.ID, Provider: r.profile, Effort: m.effort(r)}
			return m, func() tea.Msg { return choice }
		case tea.KeyUp, tea.KeyCtrlP:
			m.move(-1)
			return m, nil
		case tea.KeyDown, tea.KeyCtrlN:
			m.move(1)
			return m, nil
		case tea.KeyPgUp:
			m.move(-max(1, m.Height/2))
			return m, nil
		case tea.KeyPgDown:
			m.move(max(1, m.Height/2))
			return m, nil
		case tea.KeyLeft, tea.KeyRight:
			// Arrows edit a typed search until you move into the list.
			by := map[tea.KeyType]int{tea.KeyLeft: -1, tea.KeyRight: 1}[msg.Type]
			if (m.search.Value() == "" || m.browsing) && m.stepEffort(by) {
				return m, nil
			}
		}
	}

	before := m.search.Value()
	var cmd tea.Cmd
	m.search, cmd = m.search.Update(msg)
	if m.search.Value() != before {
		m.browsing = false
		m.Error = ""
		m.refilter(true)
	}
	return m, cmd
}

// ── view ───────────────────────────────────────────────────────────────────

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

// The row prefix is the selection bar and a space.
const modelRowPrefix = 2

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
	tail := []string{m.footer(width)}
	if r, ok := m.highlighted(); ok && !paned && height >= 16 {
		tail = append([]string{" " + m.summary(r)}, tail...)
	}
	if roomy {
		tail = append([]string{""}, tail...)
	}
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
			all = append(all, DefaultStyles.Faint.Render("  could not list models · type an id to use another"))
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
			b.WriteString(map[bool]lipgloss.Style{false: base, true: hit}[marked].Render(run))
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
		switch {
		case !selected:
			return " "
		case open:
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
		facts = append(facts, [2]string{"context", compactTokens(r.model.Context) + " tokens"})
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
		parts = append(parts, compactTokens(r.model.Context)+" context")
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
	var lines []string
	r, ok := m.highlighted()
	if !ok {
		lines = []string{"", DefaultStyles.Muted.Render("nothing matches"), DefaultStyles.Faint.Render("type a model id to use it as is")}
	} else {
		for _, l := range svWrap(r.model.ID, inner, 2) {
			lines = append(lines, DefaultStyles.Bold.Render(l))
		}
		meta := []string{DefaultStyles.Muted.Render(r.profile)}
		if protocol := m.catalog(r.profile).settings.Protocol; protocol != "" {
			meta = append(meta, DefaultStyles.Faint.Render(protocol))
		}
		if tag := m.tag(r); tag == "current" {
			meta = append(meta, DefaultStyles.Success.Render(tag))
		} else if tag != "" {
			meta = append(meta, DefaultStyles.Faint.Render(tag))
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
	}

	out := make([]string, 0, height)
	for _, l := range lines {
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

func (m ModelPickerModel) footer(width int) string {
	left := " " + keyHints(hint{"↑↓", "move"}, hint{"←→", "effort"}, hint{"enter", "switch"}, hint{"esc", "back"})
	loading := 0
	models := 0
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
	switch {
	case gap >= 3:
		return left + strings.Repeat(" ", gap) + right
	case m.Error != "":
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
