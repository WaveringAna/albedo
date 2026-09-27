// Asynchronous catalog arrival, search, keyboard selection, and cap toggles require TUI state.
package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"

	tea "charm.land/bubbletea/v2"
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
