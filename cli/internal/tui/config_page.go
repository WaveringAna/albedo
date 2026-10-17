package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// ConfigPageModel is the /config screen: the declared settings under their
// category's heading, one section for the daemon's own settings and one per
// installed extension that declares some, one row per declared field, and
// what each field is saved to or defaults to at the row's edge. enter or
// ctrl+e edits the highlighted field, ctrl+x drops its saved value so the
// default applies again, and every save carries the group validator last
// read.
type ConfigPageModel struct {
	Conn *daemon.Connection
	Form *configForm
	// Sections are the group as the daemon last reported it, in category
	// order; ETag is the validator the next save has to match.
	Sections []daemon.ExtensionSettingsSection
	ETag     string
	pageStatus
	listView
}

type configLoadedMsg struct {
	Settings daemon.ExtensionSettings
	Err      error
	Gen      int
}

type configSavedMsg struct {
	Settings daemon.ExtensionSettings
	Err      error
	Gen      int
}

type ConfigPageDoneMsg struct{}

type ChatOpenConfigPageMsg struct{}

// The row a declared field draws as, and the one a declared section with no
// fields draws as, so its problem is visible without enter.
const (
	configNoFields = "no declared settings"
	configTagWidth = 24
)

// configCategories are the headings /config groups sections under, in the
// order it shows them.
var configCategories = []struct {
	category daemon.SettingCategory
	label    string
}{
	{daemon.SettingWebSearch, "Web search"},
	{daemon.SettingContext, "Context"},
	{daemon.SettingAgents, "Agents"},
	{daemon.SettingModelsAndCaching, "Models & caching"},
	{daemon.SettingTools, "Tools"},
}

// configCategory is where category stands among the headings, and its label.
func configCategory(category daemon.SettingCategory) (int, string) {
	for i, c := range configCategories {
		if c.category == category {
			return i, c.label
		}
	}
	return len(configCategories), string(category)
}

func NewConfigPageModel(conn *daemon.Connection) ConfigPageModel {
	return ConfigPageModel{
		Conn:       conn,
		pageStatus: newPageStatus(true),
		listView:   newListView("Search settings"),
	}
}

func (m *ConfigPageModel) SetSize(width, height int) {
	m.pageStatus.SetSize(width, height)
	m.listView.setSize(width, height)
}

func (m ConfigPageModel) Init() tea.Cmd { return m.loadCmd(m.Generation) }

func (m ConfigPageModel) loadCmd(gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return configLoadedMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}
		settings, err := daemon.GetExtensionSettings(context.Background(), m.Conn)
		return configLoadedMsg{Settings: settings, Err: err, Gen: gen}
	}
}

func (m ConfigPageModel) Update(msg tea.Msg) (ConfigPageModel, tea.Cmd) {
	switch msg := msg.(type) {
	case configLoadedMsg:
		if !m.settle(msg.Gen, msg.Err, &m.Loading) {
			return m, nil
		}
		m.Error = ""
		m.adopt(msg.Settings)
		return m, nil

	case configSavedMsg:
		if msg.Gen != m.Generation {
			return m, nil
		}
		m.Saving = false
		if msg.Err != nil {
			if apiErr, ok := errors.AsType[*daemon.APIError](msg.Err); ok && apiErr.StatusCode == http.StatusPreconditionFailed {
				m.Error = ""
				m.Notice = "These settings changed elsewhere. Review them before saving again."
				m.Loading, m.Generation = true, nextPageGeneration()
				return m, m.loadCmd(m.Generation)
			}
			// The daemon refused the value: the form stays open with it.
			m.Error = msg.Err.Error()
			return m, nil
		}
		m.adopt(msg.Settings)
		m.Form, m.Error = nil, ""
		m.Notice = "Saved."
		return m, nil

	case tea.PasteMsg:
		if m.Form == nil || m.Saving {
			return m, nil
		}
		before := m.Form.value()
		_, cmd := m.Form.update(msg)
		if m.Form.value() != before {
			m.Error = m.Form.problem()
		}
		return m, cmd

	case tea.KeyPressMsg:
		switch {
		case m.Form != nil:
			return m.formKey(msg)
		case msg.String() == "esc" || msg.String() == "ctrl+c":
			return m, func() tea.Msg { return ConfigPageDoneMsg{} }
		case m.Loading || m.Saving:
			return m, nil
		}
		return m.listKey(msg)
	}
	return m, m.listView.update(msg)
}

// formKey routes keys to the open form; esc closes it without saving. A value
// the form can already tell is wrong is refused here, and the daemon's own
// refusal keeps the form open with its detail in the footer.
func (m ConfigPageModel) formKey(msg tea.KeyPressMsg) (ConfigPageModel, tea.Cmd) {
	if m.Saving {
		return m, nil
	}
	if msg.String() == "esc" {
		m.Form, m.Error = nil, ""
		return m, nil
	}
	before := m.Form.value()
	submit, cmd := m.Form.update(msg)
	if m.Form.value() != before {
		m.Error = m.Form.problem()
	}
	if !submit {
		return m, cmd
	}
	value, err := m.Form.encoded()
	if err != nil {
		m.Error = err.Error()
		return m, nil
	}
	return m.save(m.Form.Section, m.Form.Setting.Key, value)
}

// listKey acts on the highlighted field, or hands the key to the filter.
func (m ConfigPageModel) listKey(msg tea.KeyPressMsg) (ConfigPageModel, tea.Cmd) {
	section, setting, ok := m.current()
	switch msg.String() {
	case "enter", "ctrl+e":
		if ok {
			m.Error, m.Notice = "", ""
			m.Form = newConfigForm(section.Name, setting)
		}
	case "ctrl+x":
		if ok && setting.Saved.Set() {
			return m.save(section.Name, setting.Key, nil)
		}
	case "ctrl+r":
		m.Error, m.Notice, m.Loading = "", "", true
		m.Generation = nextPageGeneration()
		return m, m.loadCmd(m.Generation)
	default:
		return m, m.listView.update(msg)
	}
	return m, nil
}

// save sends one value under the observed group validator; a nil value is
// JSON null, which drops the saved value so the default applies.
func (m ConfigPageModel) save(section, key string, value json.RawMessage) (ConfigPageModel, tea.Cmd) {
	m.Saving, m.Error = true, ""
	m.Generation = nextPageGeneration()
	gen, etag := m.Generation, m.ETag
	return m, func() tea.Msg {
		settings, err := daemon.SaveExtensionSetting(context.Background(), m.Conn, etag, section, key, value)
		return configSavedMsg{Settings: settings, Err: err, Gen: gen}
	}
}

// adopt replaces the group and rebuilds the rows, which keeps the cursor on
// the same section and key. Sections keep the daemon's order within their
// category.
func (m *ConfigPageModel) adopt(settings daemon.ExtensionSettings) {
	m.Sections, m.ETag = slices.Clone(settings.Sections), settings.ETag
	slices.SortStableFunc(m.Sections, func(a, b daemon.ExtensionSettingsSection) int {
		ai, _ := configCategory(a.Category)
		bi, _ := configCategory(b.Category)
		return cmp.Compare(ai, bi)
	})
	var rows []listEntry
	for _, section := range m.Sections {
		if len(section.Fields) == 0 {
			rows = append(rows, m.sectionEntry(section))
			continue
		}
		for _, setting := range section.Fields {
			rows = append(rows, m.settingEntry(section, setting))
		}
	}
	m.setRows(rows)
}

// current is the declared field under the cursor. Rows group under their
// section's label, so they are matched by key, which holds the section name.
func (m ConfigPageModel) current() (daemon.ExtensionSettingsSection, daemon.ExtensionSetting, bool) {
	row, ok := m.highlighted()
	if !ok {
		return daemon.ExtensionSettingsSection{}, daemon.ExtensionSetting{}, false
	}
	for _, section := range m.Sections {
		for _, setting := range section.Fields {
			if configRowKey(section.Name, setting.Key) == row.key {
				return section, setting, true
			}
		}
	}
	return daemon.ExtensionSettingsSection{}, daemon.ExtensionSetting{}, false
}

func configRowKey(section, key string) string { return section + "/" + key }

// settingEntry is one declared field: its label, and what it is saved to or
// defaults to at the edge.
func (m ConfigPageModel) settingEntry(section daemon.ExtensionSettingsSection, setting daemon.ExtensionSetting) listEntry {
	_, category := configCategory(section.Category)
	entry := m.sectionProblem(listEntry{
		key:     configRowKey(section.Name, setting.Key),
		group:   category,
		section: section.Label,
		name:    setting.Label,
		search:  []string{setting.Key, section.Name, section.Label, category, setting.Description},
	}, section)
	entry.tag = configTag(setting)
	entry.detail = func(width int) []string { return m.settingDetails(section, setting, width) }
	return entry
}

// sectionEntry stands in for a declared section that has no fields, so a
// problem it reports is still seen without enter.
func (m ConfigPageModel) sectionEntry(section daemon.ExtensionSettingsSection) listEntry {
	_, category := configCategory(section.Category)
	entry := m.sectionProblem(listEntry{
		key:     configRowKey(section.Name, ""),
		group:   category,
		section: section.Label,
		name:    configNoFields,
		search:  []string{section.Name, section.Label, category, section.Description},
	}, section)
	entry.detail = func(width int) []string { return m.sectionDetails(section, width) }
	return entry
}

// sectionProblem puts what the section's owner says about its saved section on
// every row of that section.
func (m ConfigPageModel) sectionProblem(entry listEntry, section daemon.ExtensionSettingsSection) listEntry {
	if section.Problem != "" {
		entry.lead = DefaultStyles.Warning.Render("problem")
		entry.desc = section.Problem
	}
	return entry
}

// configTag is what a row shows at its edge: the saved value in bold, or the
// default in muted style, the colour alone saying it is only the default.
func configTag(setting daemon.ExtensionSetting) string {
	if setting.Saved.Set() {
		return DefaultStyles.Bold.Render(ansi.Truncate(configValue(setting, setting.Saved), configTagWidth, "…"))
	}
	return DefaultStyles.Muted.Render(ansi.Truncate(configDefault(setting), configTagWidth, "…"))
}

// settingDetails is the pane: what the setting is, what it takes, and what it
// holds now.
func (m ConfigPageModel) settingDetails(section daemon.ExtensionSettingsSection, setting daemon.ExtensionSetting, width int) []string {
	lines := paneTitle(setting.Label, setting.Description, width)
	lines = append(lines, factRows("section", section.Name, width)...)
	lines = append(lines, factRows("key", setting.Key, width)...)
	lines = append(lines, factRows("kind", string(setting.Kind), width)...)
	lines = append(lines, factRows("range", configRule(setting), width)...)
	lines = append(lines, factRows("default", configDefault(setting), width)...)
	lines = append(lines, factRows("saved", configSaved(setting), width)...)
	if section.Problem != "" {
		lines = append(lines, factRows("problem", section.Problem, width)...)
	}
	return lines
}

func (m ConfigPageModel) sectionDetails(section daemon.ExtensionSettingsSection, width int) []string {
	lines := paneTitle(section.Label, section.Description, width)
	lines = append(lines, factRows("section", section.Name, width)...)
	if section.Problem != "" {
		lines = append(lines, factRows("problem", section.Problem, width)...)
	}
	return append(lines, paneNote("This section declares no settings.", width)...)
}

// hints are the keys this screen answers now; editing keys are left out when
// no declared field is highlighted.
func (m ConfigPageModel) hints(setting daemon.ExtensionSetting, ok bool) []hint {
	hints := []hint{{"↑↓", "move"}}
	if ok {
		hints = append(hints, hint{"enter", "edit"}, hint{"ctrl+e", "edit"})
		if setting.Saved.Set() {
			hints = append(hints, hint{"ctrl+x", "reset"})
		}
	}
	return append(hints, hint{"ctrl+r", "refresh"}, hint{"esc", "back"})
}

// status is the footer's one line: work in flight, the last refusal or
// notice, or how many extensions declare settings.
func (m ConfigPageModel) status() (string, bool) {
	if m.Form != nil && !m.Saving && !m.Loading && m.Error == "" && m.Notice == "" {
		return "", false
	}
	switch {
	case m.Saving:
		return DefaultStyles.Busy.Render("saving…"), true
	case m.Loading:
		return DefaultStyles.Faint.Render("loading…"), false
	case m.Error != "":
		return DefaultStyles.Error.Render(m.Error), true
	case m.Notice != "":
		return DefaultStyles.Warning.Render(m.Notice), true
	}
	return DefaultStyles.Faint.Render(counted(len(m.Sections), "section")), false
}

func (m ConfigPageModel) footer(width int) string {
	status, urgent := m.status()
	if m.Form != nil {
		return footerLine(width, []hint{{"enter", "save"}, {"ctrl+s", "save"}, {"esc", "cancel"}}, status, urgent)
	}
	_, setting, ok := m.current()
	return footerLine(width, m.hints(setting, ok), status, urgent)
}

// summary is the highlighted row's place and rule, for a width too narrow for
// the detail pane.
func (m ConfigPageModel) summary() string {
	section, setting, ok := m.current()
	if !ok {
		return ""
	}
	return section.Name + " · " + configRule(setting)
}

// formList is the open form in the list's place, clipped to its rows.
func (m ConfigPageModel) formList(width, height int) []string {
	rows := m.Form.view(width)
	return rows[:min(len(rows), height)]
}

func (m ConfigPageModel) View() string {
	width := max(1, m.Width)
	lv := m.listView
	lv.Empty = "Nothing declares settings."
	switch {
	case m.Loading:
		lv.Empty = "loading settings…"
	case m.Error != "" && len(m.Sections) == 0:
		lv.Empty = "Could not load settings; the reason is in the footer."
	}
	frame := lv.frame(brand("albedo")+" "+DefaultStyles.Muted.Render("/config"), "", m.footer(width))
	if m.Form != nil {
		frame.filter, frame.pane, frame.list = "", nil, m.formList
	} else {
		frame.summary = m.summary()
	}
	return frame.view(m.Width, m.Height)
}
