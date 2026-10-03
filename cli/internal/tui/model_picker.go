package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"maps"
	"slices"
	"strings"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
)

// The /model picker lists every saved profile's models at once, grouped by
// profile, and lets each row carry a reasoning effort before you switch.

type ModelPickerSelectMsg struct {
	// RaiseCap is set when you changed the model's context cap here: true
	// raises it to the provider's maximum, false restores the default window.
	RaiseCap *bool
	CapKey   string
	Model    string
	Provider string
	// Effort is the chosen reasoning level. Empty lets the daemon choose.
	Effort string
}

type ModelPickerCancelMsg struct{}

type modelCatalogLoadedMsg struct {
	Generation int
	Err        error
	Profile    string
	Models     []daemon.Model
}

// profileCatalog is one profile's models: the ones the session and the
// profile already use, then whatever the daemon lists.
type profileCatalog struct {
	settings config.Settings
	name     string
	models   []daemon.Model
	loading  bool
	failed   bool
}

// modelRow is a row you can pick: a profile's model, or the search text sent
// to a profile as a model id.
type modelRow struct {
	profile string
	// hits are the byte offsets of the id's characters the search matched.
	hits  []int
	model daemon.Model
	typed bool
}

func (r modelRow) key() string {
	if r.typed {
		return "typed\x00" + r.profile
	}
	return r.profile + "\x00" + r.model.ID
}

type ModelPickerModel struct {
	Generation  int
	readCtx     context.Context
	cancelReads context.CancelFunc
	Conn        *daemon.Connection
	// caps are cap choices made here, by model id: the cap is per model, so
	// the same model under two profiles shares it.
	caps    map[string]bool
	efforts map[string]string
	// The session's selection when the picker opened.
	Profile, Model, Effort string
	Error                  string
	rows                   []modelRow

	catalogs      []profileCatalog
	search        textinput.Model
	Width, Height int
	cursor        int
	Saving        bool
	// browsing is set once you move through the list, so arrows change the
	// effort even while a search is typed.
	browsing bool
}

func NewModelPickerModel(conn *daemon.Connection, profiles config.Profiles, model, profile, effort string) ModelPickerModel {
	if profile == "" {
		profile = profiles.Active
	}
	names := slices.Sorted(maps.Keys(profiles.Providers))
	slices.SortStableFunc(names, func(a, b string) int {
		if a == b {
			return 0
		}
		if a == profile {
			return -1
		}
		if b == profile {
			return 1
		}
		return 0
	})

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

	search := newField()
	search.Placeholder = "Search models or type a model ID"
	st := search.Styles()
	st.Focused.Placeholder, st.Blurred.Placeholder = DefaultStyles.Faint, DefaultStyles.Faint
	search.SetStyles(st)
	search.Focus()

	readCtx, cancelReads := context.WithCancel(context.Background())
	m := ModelPickerModel{
		Generation:  nextPageGeneration(),
		readCtx:     readCtx,
		cancelReads: cancelReads,
		Conn:        conn,
		Profile:     profile,
		Model:       model,
		Effort:      effort,
		catalogs:    catalogs,
		efforts:     map[string]string{},
		caps:        map[string]bool{},
		search:      search,
	}
	m.refilter(true)
	current := modelRow{profile: profile, model: daemon.Model{ID: model}}.key()
	m.cursor = max(0, slices.IndexFunc(m.rows, func(r modelRow) bool { return r.key() == current }))
	return m
}

func (m *ModelPickerModel) SetSize(width, height int) {
	m.Width = width
	m.Height = height
	m.search.SetWidth(max(1, width-6))
}

func (m *ModelPickerModel) Close() {
	if m.cancelReads != nil {
		m.cancelReads()
	}
	m.Generation = nextPageGeneration()
}

func (m ModelPickerModel) Init() tea.Cmd {
	cmds := []tea.Cmd{textinput.Blink}
	for _, c := range m.catalogs {
		cmds = append(cmds, m.listCmd(c))
	}
	return tea.Batch(cmds...)
}

func (m ModelPickerModel) listCmd(c profileCatalog) tea.Cmd {
	conn, ctx, generation := m.Conn, m.readCtx, m.Generation
	return func() tea.Msg {
		if conn == nil {
			return modelCatalogLoadedMsg{Generation: generation, Profile: c.name, Err: errors.New("daemon connection unavailable")}
		}
		models, err := daemon.ListProfileModels(ctx, conn, c.settings)
		return modelCatalogLoadedMsg{Generation: generation, Profile: c.name, Models: models, Err: err}
	}
}

func utf16Length(s string) int {
	length := 0
	for _, char := range s {
		length++
		if char > 0xffff {
			length++
		}
	}
	return length
}

func validateModelID(m string) error {
	m = strings.TrimSpace(m)
	if m == "" || utf16Length(m) > 512 || strings.ContainsFunc(m, func(r rune) bool { return r < 0x20 || r == 0x7f }) {
		return errors.New("enter a model id of 1–512 characters")
	}
	return nil
}

// searchKey folds case and separators, so "gpt.5" finds "gpt-5.1".
const searchSeparators = " -_.:/"

func (m ModelPickerModel) highlighted() (modelRow, bool) {
	if m.cursor < 0 || m.cursor >= len(m.rows) {
		return modelRow{}, false
	}
	return m.rows[m.cursor], true
}

func (m ModelPickerModel) catalog(profile string) profileCatalog {
	if i := slices.IndexFunc(m.catalogs, func(c profileCatalog) bool { return c.name == profile }); i >= 0 {
		return m.catalogs[i]
	}
	return profileCatalog{}
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

// raisable reports whether a model's provider offers a window past its default.
func raisable(model daemon.Model) bool {
	return model.MaxContext > model.Context && model.Context > 0
}

// raised is the cap a row would switch with: your choice here, else the saved one.
func (m ModelPickerModel) raised(r modelRow) bool {
	if raised, ok := m.caps[r.model.CapKey]; ok {
		return raised
	}
	return r.model.Raised
}

// window is the context a row would switch with.
func (m ModelPickerModel) window(r modelRow) int {
	if raisable(r.model) && m.raised(r) {
		return r.model.MaxContext
	}
	return r.model.Context
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
		if msg.Generation != m.Generation {
			return m, nil
		}
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

	case tea.KeyPressMsg:
		if m.Saving {
			return m, nil
		}
		switch msg.String() {
		case "esc", "ctrl+c", "ctrl+d":
			return m, func() tea.Msg { return ModelPickerCancelMsg{} }
		case "enter":
			r, ok := m.highlighted()
			if !ok {
				return m, nil
			}
			if err := validateModelID(r.model.ID); err != nil {
				m.Error = err.Error()
				return m, nil
			}
			m.Error = ""
			choice := ModelPickerSelectMsg{Model: r.model.ID, CapKey: r.model.CapKey, Provider: r.profile, Effort: m.effort(r)}
			if raised, changed := m.caps[r.model.CapKey]; changed && raised != r.model.Raised {
				choice.RaiseCap = &raised
			}
			return m, func() tea.Msg { return choice }
		case "up", "ctrl+p", "down", "ctrl+n", "pgup", "pgdown":
			m.move(map[string]int{"up": -1, "ctrl+p": -1, "down": 1, "ctrl+n": 1, "pgup": -max(1, m.Height/2), "pgdown": max(1, m.Height/2)}[msg.String()])
			return m, nil
		case "tab":
			if r, ok := m.highlighted(); ok && raisable(r.model) {
				m.caps[r.model.CapKey] = !m.raised(r)
				return m, nil
			}
		case "left", "right":
			// Arrows edit a typed search until you move into the list.
			by := map[string]int{"left": -1, "right": 1}[msg.String()]
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

// The row prefix is the selection bar and a space.
const modelRowPrefix = 2
