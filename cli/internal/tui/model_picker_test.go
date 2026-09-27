package tui

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

var pickerProfiles = config.Profiles{
	Active: "work",
	Providers: map[string]config.Settings{
		"work":  {Extension: "openai", BaseURL: "https://work.example/v1", Model: "gpt-5", Protocol: "responses"},
		"codex": {Extension: "codex", Model: "gpt-5-codex", Protocol: "responses"},
	},
}

var reasoning = []string{"low", "medium", "high"}

func loadedPicker(t *testing.T) ModelPickerModel {
	t.Helper()
	m := NewModelPickerModel(nil, pickerProfiles, "gpt-5", "work", "high")
	m.SetSize(120, 30)
	m, _ = m.Update(modelCatalogLoadedMsg{Profile: "work", Models: []daemon.Model{
		{ID: "gpt-4.1", Context: 1_047_576},
		{ID: "gpt-5", Efforts: reasoning, Context: 400_000, Output: 128_000, Input: []string{"text", "image"}},
		{ID: "o4-mini", Efforts: []string{"low", "medium"}},
	}})
	m, _ = m.Update(modelCatalogLoadedMsg{Profile: "codex", Models: []daemon.Model{
		{ID: "gpt-5-codex", Efforts: []string{"minimal", "low", "medium", "high"}},
	}})
	return m
}

func pickerKey(m ModelPickerModel, keys ...tea.KeyPressMsg) ModelPickerModel {
	for _, k := range keys {
		m, _ = m.Update(k)
	}
	return m
}

func typed(s string) tea.KeyPressMsg { return tea.KeyPressMsg{Code: tea.KeyExtended, Text: s} }

func chosen(t *testing.T, m ModelPickerModel) ModelPickerSelectMsg {
	t.Helper()
	_, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("enter chose nothing")
	}
	msg, ok := cmd().(ModelPickerSelectMsg)
	if !ok {
		t.Fatalf("enter sent %T", cmd())
	}
	return msg
}

func rowIDs(m ModelPickerModel) []string {
	ids := make([]string, len(m.rows))
	for i, r := range m.rows {
		ids[i] = r.profile + "/" + r.model.ID
		if r.typed {
			ids[i] = "typed:" + ids[i]
		}
	}
	return ids
}

func TestModelPickerGroupsProfilesWithTheSessionsFirst(t *testing.T) {
	m := loadedPicker(t)
	got := strings.Join(rowIDs(m), " ")
	want := "work/gpt-5 work/gpt-4.1 work/o4-mini codex/gpt-5-codex"
	if got != want {
		t.Fatalf("rows %q, want %q", got, want)
	}
	if r, _ := m.highlighted(); r.model.ID != "gpt-5" || r.profile != "work" {
		t.Fatalf("cursor on %+v, want the session's model", r)
	}
	// The seeded row picked up the listing's facts.
	if r, _ := m.highlighted(); r.model.Context != 400_000 {
		t.Fatalf("seed kept no catalog facts: %+v", r.model)
	}
}

func TestModelPickerKeepsTheCursorWhenAListingArrives(t *testing.T) {
	m := NewModelPickerModel(nil, pickerProfiles, "gpt-5", "work", "")
	m = pickerKey(m, tea.KeyPressMsg{Code: tea.KeyDown})
	before, _ := m.highlighted()
	m, _ = m.Update(modelCatalogLoadedMsg{Profile: "work", Models: []daemon.Model{{ID: "a"}, {ID: "b"}}})
	if after, _ := m.highlighted(); after.key() != before.key() {
		t.Fatalf("cursor moved from %s to %s", before.key(), after.key())
	}
}

func TestModelPickerArrowsStepEffortAndEnterSendsIt(t *testing.T) {
	m := loadedPicker(t)
	if got := chosen(t, m); got.Effort != "high" || got.Model != "gpt-5" || got.Provider != "work" {
		t.Fatalf("unchanged choice %+v, want the session's high effort", got)
	}
	m = pickerKey(m, tea.KeyPressMsg{Code: tea.KeyLeft}, tea.KeyPressMsg{Code: tea.KeyLeft}, tea.KeyPressMsg{Code: tea.KeyLeft})
	if got := chosen(t, m); got.Effort != "low" {
		t.Fatalf("effort %q after stepping down past the end, want low", got.Effort)
	}
	m = pickerKey(m, tea.KeyPressMsg{Code: tea.KeyRight})
	if got := chosen(t, m); got.Effort != "medium" {
		t.Fatalf("effort %q, want medium", got.Effort)
	}
	// Another row lacking the session's level shows the daemon's default,
	// and the first row keeps its pick.
	m = pickerKey(m, tea.KeyPressMsg{Code: tea.KeyDown}, tea.KeyPressMsg{Code: tea.KeyDown})
	if got := chosen(t, m); got.Model != "o4-mini" || got.Effort != "medium" {
		t.Fatalf("choice %+v, want o4-mini at medium", got)
	}
	m = pickerKey(m, tea.KeyPressMsg{Code: tea.KeyUp}, tea.KeyPressMsg{Code: tea.KeyUp})
	if got := chosen(t, m); got.Effort != "medium" {
		t.Fatalf("first row forgot its pick: %+v", got)
	}
	// A model without levels sends none.
	m = pickerKey(m, tea.KeyPressMsg{Code: tea.KeyDown}, tea.KeyPressMsg{Code: tea.KeyRight})
	if got := chosen(t, m); got.Model != "gpt-4.1" || got.Effort != "" {
		t.Fatalf("choice %+v, want gpt-4.1 without effort", got)
	}
}

func TestModelPickerArrowsEditASearchUntilYouBrowse(t *testing.T) {
	m := loadedPicker(t)
	m = pickerKey(m, typed("codex"))
	if got := strings.Join(rowIDs(m), " "); got != "codex/gpt-5-codex typed:work/codex typed:codex/codex" {
		t.Fatalf("search rows %q", got)
	}
	m = pickerKey(m, tea.KeyPressMsg{Code: tea.KeyLeft}, typed("x"))
	if m.search.Value() != "codexx" {
		t.Fatalf("left arrow did not reach the search: %q", m.search.Value())
	}
	m = pickerKey(m, tea.KeyPressMsg{Code: tea.KeyBackspace}, tea.KeyPressMsg{Code: tea.KeyUp}, tea.KeyPressMsg{Code: tea.KeyLeft})
	if got := chosen(t, m); got.Model != "gpt-5-codex" || got.Effort != "medium" {
		t.Fatalf("after browsing, left should lower high to medium: %+v", got)
	}
}

func TestModelPickerSearchFoldsSeparators(t *testing.T) {
	m := pickerKey(loadedPicker(t), typed("gpt5 work"))
	if got := strings.Join(rowIDs(m), " "); got != "work/gpt-5" {
		t.Fatalf("rows %q, want work/gpt-5", got)
	}
}

func TestModelPickerSearchIsFuzzyAndHighlightsTheMatch(t *testing.T) {
	m := pickerKey(loadedPicker(t), typed("g5c"))
	if got := strings.Join(rowIDs(m), " "); got != "codex/gpt-5-codex typed:work/g5c typed:codex/g5c" {
		t.Fatalf("rows %q", got)
	}
	if got := m.rows[0].hits; !slices.Equal(got, []int{0, 4, 6}) {
		t.Fatalf("hits %v, want g, 5 and c of gpt-5-codex", got)
	}
	if got := ansi.Strip(markedCell("gpt-5-codex", []int{0, 4, 6}, 8, lipgloss.NewStyle())); got != "gpt-5-c…" {
		t.Fatalf("marked cell %q, want the plain id fitted", got)
	}
}

func TestModelPickerSearchRanksRowsAndProfiles(t *testing.T) {
	m := NewModelPickerModel(nil, pickerProfiles, "gpt-5", "work", "")
	m, _ = m.Update(modelCatalogLoadedMsg{Profile: "work", Models: []daemon.Model{{ID: "alpha-model"}, {ID: "old-alpha"}}})
	m, _ = m.Update(modelCatalogLoadedMsg{Profile: "codex", Models: []daemon.Model{{ID: "alpha"}}})
	m = pickerKey(m, typed("alpha"))
	// codex lists the exact id, so its profile leads, and within work the
	// match at the start of an id beats one later on.
	if got := strings.Join(rowIDs(m), " "); got != "codex/alpha work/alpha-model work/old-alpha typed:work/alpha" {
		t.Fatalf("rows %q", got)
	}
	if r, _ := m.highlighted(); r.model.ID != "alpha" {
		t.Fatalf("cursor on %+v, want the best match", r)
	}
	view := ansi.Strip(m.View())
	if strings.Index(view, "─ codex 1") > strings.Index(view, "─ work 2") {
		t.Fatalf("codex heading should come first:\n%s", view)
	}
}

func TestModelPickerSearchPrefersWordsTypedFromTheStart(t *testing.T) {
	m := NewModelPickerModel(nil, config.Profiles{Active: "work", Providers: map[string]config.Settings{
		"work": pickerProfiles.Providers["work"],
	}}, "gpt-5", "work", "")
	m, _ = m.Update(modelCatalogLoadedMsg{Profile: "work", Models: []daemon.Model{
		{ID: "gemini-3.1-pro"}, {ID: "gpt-oss-120b"}, {ID: "o4-mini"}, {ID: "kimi-k2"},
	}})
	for query, want := range map[string]string{
		// The p after a separator scores more than an adjacent p, but gp
		// starts gpt-oss.
		"gp":  "work/gpt-5 work/gpt-oss-120b work/gemini-3.1-pro",
		"pro": "work/gemini-3.1-pro",
		"k2":  "work/kimi-k2",
	} {
		m.search.SetValue(query)
		m.refilter(true)
		rows := slices.DeleteFunc(rowIDs(m), func(id string) bool { return strings.HasPrefix(id, "typed:") })
		if got := strings.Join(rows, " "); got != want {
			t.Fatalf("%q: rows %q, want %q", query, got, want)
		}
	}
}

func TestModelPickerOffersATypedIDToEveryProfileMissingIt(t *testing.T) {
	m := pickerKey(loadedPicker(t), typed("gpt-5-codex"))
	got := strings.Join(rowIDs(m), " ")
	if got != "codex/gpt-5-codex typed:work/gpt-5-codex" {
		t.Fatalf("rows %q", got)
	}
	m = pickerKey(m, tea.KeyPressMsg{Code: tea.KeyDown})
	if got := chosen(t, m); got.Model != "gpt-5-codex" || got.Provider != "work" || got.Effort != "" {
		t.Fatalf("typed choice %+v", got)
	}
}

func TestModelPickerViewFitsEveryWidth(t *testing.T) {
	for _, size := range [][2]int{{30, 10}, {60, 20}, {80, 24}, {100, 30}, {160, 40}} {
		m := loadedPicker(t)
		m.SetSize(size[0], size[1])
		view := m.View()
		lines := strings.Split(view, "\n")
		if len(lines) > size[1] {
			t.Fatalf("%v: %d lines", size, len(lines))
		}
		for _, line := range lines {
			if w := ansi.StringWidth(line); w > size[0] {
				t.Fatalf("%v: line is %d cells wide: %q", size, w, ansi.Strip(line))
			}
		}
	}
}

func TestModelPickerViewShowsProfilesLadderAndDetails(t *testing.T) {
	m := loadedPicker(t)
	m.SetSize(120, 30)
	view := ansi.Strip(m.View())
	for _, want := range []string{"─ work 3", "─ codex 1", "‹ ▰▰▰", "› high", "current", "default", "400k tokens", "text, image"} {
		if !strings.Contains(view, want) {
			t.Fatalf("view lacks %q:\n%s", want, view)
		}
	}
	if strings.Count(view, "‹") != 1 {
		t.Fatalf("arrows belong to the selected row only:\n%s", view)
	}
	m = pickerKey(m, tea.KeyPressMsg{Code: tea.KeyDown})
	if view := ansi.Strip(m.View()); !strings.Contains(view, "1.05m tokens") {
		t.Fatalf("details did not follow the cursor:\n%s", view)
	}
}

// pickerDaemon answers the model listing and records /model commands.
type pickerDaemon struct {
	mu       sync.Mutex
	listings []string
	commands []map[string]any
}

func (d *pickerDaemon) serve(t *testing.T) *daemon.Connection {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		d.mu.Lock()
		defer d.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasPrefix(r.URL.Path, "/models/"):
			d.listings = append(d.listings, r.URL.RequestURI())
			_ = json.NewEncoder(w).Encode([]any{map[string]any{"id": "gpt-5", "efforts": reasoning}, "bare"})
		case strings.HasSuffix(r.URL.Path, "/commands"):
			var body map[string]any
			_ = json.NewDecoder(r.Body).Decode(&body)
			d.commands = append(d.commands, body)
			_ = json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"model": "gpt-5", "provider": "work", "effort": "low"}})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(server.Close)
	parsed, _ := url.Parse(server.URL)
	port, _ := strconv.Atoi(parsed.Port())
	return daemon.NewConnection(daemon.ConnectionSnapshot{Port: port, Token: fakeToken, Version: 2}, "")
}

func TestModelPickerListsWithDetailsAndSwitchesWithTheChosenEffort(t *testing.T) {
	d := &pickerDaemon{}
	conn := d.serve(t)
	session := daemon.Session{ID: "s1", Model: "gpt-5", Provider: "work", Effort: "medium"}
	app := NewAppModel(conn, config.Profiles{Active: "work", Providers: map[string]config.Settings{
		"work": pickerProfiles.Providers["work"],
	}}, &session, "/work", false)

	updated, _ := app.Update(ChatOpenModelPickerMsg{})
	app = updated.(AppModel)
	listing := app.ModelPicker.listCmd(app.ModelPicker.catalogs[0])()
	updated, _ = app.Update(listing)
	app = updated.(AppModel)
	if len(d.listings) != 1 || !strings.Contains(d.listings[0], "details=1") {
		t.Fatalf("listing requests %v", d.listings)
	}
	if got := strings.Join(rowIDs(app.ModelPicker), " "); got != "work/gpt-5 work/bare" {
		t.Fatalf("rows %q", got)
	}

	updated, _ = app.Update(tea.KeyPressMsg{Code: tea.KeyLeft})
	app = updated.(AppModel)
	updated, cmd := app.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	app = updated.(AppModel)
	updated, cmd = app.Update(cmd())
	app = updated.(AppModel)
	updated, _ = app.Update(cmd())
	app = updated.(AppModel)

	if len(d.commands) != 1 {
		t.Fatalf("commands %v", d.commands)
	}
	args, _ := d.commands[0]["args"].(map[string]any)
	if d.commands[0]["name"] != "/model" || args["model"] != "gpt-5" || args["provider"] != "work" || args["effort"] != "low" {
		t.Fatalf("switch sent %v", d.commands[0])
	}
	if app.State != AppStateChat || app.ActiveSession.Effort != "low" {
		t.Fatalf("state %v effort %q after the switch", app.State, app.ActiveSession.Effort)
	}
}

// A model whose provider offers a window past its default shows a cap toggle;
// tab flips it, and enter sends the change only when it differs from the saved
// cap.
func TestModelPickerTabRaisesAModelsContextCap(t *testing.T) {
	m := NewModelPickerModel(nil, pickerProfiles, "gpt-5-codex", "codex", "")
	m.SetSize(140, 30)
	m, _ = m.Update(modelCatalogLoadedMsg{Profile: "codex", Models: []daemon.Model{
		{ID: "gpt-6-astra", Context: 272_000, MaxContext: 872_000, Efforts: reasoning},
		{ID: "gpt-6-sol", Context: 272_000, MaxContext: 872_000, Raised: true},
		{ID: "gpt-5.5", Context: 272_000},
	}})
	m = pickerKey(m, typed("astra"))
	if view := ansi.Strip(m.View()); !strings.Contains(view, "tab raises to 872k") || !strings.Contains(view, "272k tokens") {
		t.Fatalf("astra should offer to raise its cap:\n%s", view)
	}
	m = pickerKey(m, tea.KeyPressMsg{Code: tea.KeyTab})
	if view := ansi.Strip(m.View()); !strings.Contains(view, "872k tokens") || !strings.Contains(view, "tab restores 272k") {
		t.Fatalf("a raised cap should show the larger window:\n%s", view)
	}
	if got := chosen(t, m).RaiseCap; got == nil || !*got {
		t.Fatalf("enter should raise astra's cap, got %v", got)
	}
	// Flipping back leaves the saved cap alone.
	m = pickerKey(m, tea.KeyPressMsg{Code: tea.KeyTab})
	if got := chosen(t, m).RaiseCap; got != nil {
		t.Fatalf("an unchanged cap should send nothing, got %v", *got)
	}

	// A saved raise shows as raised, and tab restores the default.
	sol := pickerKey(m, tea.KeyPressMsg{Code: tea.KeyBackspace}, tea.KeyPressMsg{Code: tea.KeyBackspace},
		tea.KeyPressMsg{Code: tea.KeyBackspace}, tea.KeyPressMsg{Code: tea.KeyBackspace},
		tea.KeyPressMsg{Code: tea.KeyBackspace}, typed("6-sol"))
	if view := ansi.Strip(sol.View()); !strings.Contains(view, "tab restores 272k") {
		t.Fatalf("sol's saved raise should show:\n%s", view)
	}
	sol = pickerKey(sol, tea.KeyPressMsg{Code: tea.KeyTab})
	if got := chosen(t, sol).RaiseCap; got == nil || *got {
		t.Fatalf("tab should restore sol's default window, got %v", got)
	}

	// Nothing to raise, nothing to toggle.
	older := pickerKey(sol, tea.KeyPressMsg{Code: tea.KeyBackspace}, tea.KeyPressMsg{Code: tea.KeyBackspace},
		tea.KeyPressMsg{Code: tea.KeyBackspace}, tea.KeyPressMsg{Code: tea.KeyBackspace},
		tea.KeyPressMsg{Code: tea.KeyBackspace}, typed("5.5"), tea.KeyPressMsg{Code: tea.KeyTab})
	if view := ansi.Strip(older.View()); strings.Contains(view, "tab raises") || strings.Contains(view, "tab cap") {
		t.Fatalf("gpt-5.5 has no cap to raise:\n%s", view)
	}
	if got := chosen(t, older).RaiseCap; got != nil {
		t.Fatalf("gpt-5.5 should send no cap, got %v", *got)
	}
}
