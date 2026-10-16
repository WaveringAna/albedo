// Stale replies, a refused value that keeps the form, and the reload a stale
// validator starts operate on unexported screen state that the daemon E2E
// cannot interleave or read: the same keys there always reach a settled
// daemon, and the form's own text is not part of any request.
package tui

import (
	"albedo/cli/internal/daemon"
	"encoding/json"
	"net/http"
	"testing"

	tea "charm.land/bubbletea/v2"
)

// configSections are the declared settings the unit tests load, in registry
// order: one integer with a saved value, and one text setting that is not
// saved. /config shows the web search section first.
func configSections() []daemon.ExtensionSettingsSection {
	return []daemon.ExtensionSettingsSection{
		{Name: "rolling", Label: "Rolling summary compaction", Category: daemon.SettingContext, Description: "Incremental summary", Fields: []daemon.ExtensionSetting{
			{Key: "triggerPercent", Label: "Trigger", Description: "Percent of the window at which a compaction runs.", Kind: daemon.SettingInteger, Minimum: new(int64(1)), Maximum: new(int64(99)), Default: daemon.SettingValue{Number: new(int64(80))}, Saved: daemon.SettingValue{Number: new(int64(70))}},
		}},
		{Name: "exa", Label: "Exa web search", Category: daemon.SettingWebSearch, Description: "Search through exa", Fields: []daemon.ExtensionSetting{
			{Key: "endpoint", Label: "Endpoint", Description: "Base URL of the exa API.", Kind: daemon.SettingText, Default: daemon.SettingValue{Text: new("https://api.exa.ai")}},
		}},
	}
}

func loadedConfigPage(t *testing.T, conn *daemon.Connection) ConfigPageModel {
	t.Helper()
	m := NewConfigPageModel(conn)
	m.SetSize(100, 30)
	m, _ = m.Update(configLoadedMsg{Gen: m.Generation, Settings: daemon.ExtensionSettings{Sections: configSections(), ETag: `"settings-a"`}})
	return m
}

func configKeyPress(code rune, mod tea.KeyMod) tea.KeyPressMsg {
	return tea.KeyPressMsg{Code: code, Mod: mod}
}

// A reply from a load an escape or a refresh replaced must not settle the
// newer request, and must not overwrite the rows it already drew.
func TestConfigStaleReplyIsDropped(t *testing.T) {
	m := loadedConfigPage(t, nil)
	m, _ = m.Update(configKeyPress('r', tea.ModCtrl))
	zombie := configLoadedMsg{Gen: m.Generation, Settings: daemon.ExtensionSettings{ETag: `"settings-a"`}}
	m.Generation = nextPageGeneration()
	m.Loading = true
	m, _ = m.Update(zombie)
	if !m.Loading {
		t.Fatal("a stale load reply settled the load in flight")
	}
	if len(m.Sections) != 2 {
		t.Fatalf("a stale reply replaced the rows: %+v", m.Sections)
	}
}

// The daemon's refusal detail belongs in the footer with the value still
// typed, so the next attempt does not have to be retyped.
func TestConfigRefusalKeepsTheFormAndItsValue(t *testing.T) {
	m := loadedConfigPage(t, nil)
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
	m, _ = m.Update(configKeyPress('e', tea.ModCtrl))
	if m.Form == nil {
		t.Fatal("ctrl+e did not open the form")
	}
	m.Form.Inputs[configFieldValue].SetValue("10")
	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if !m.Saving || cmd == nil {
		t.Fatal("enter did not start a save")
	}
	refusal := &daemon.APIError{StatusCode: http.StatusBadRequest, Code: "invalid_settings", Message: "rolling percentages must satisfy 0 < tailPercent < triggerPercent < 100"}
	m, _ = m.Update(configSavedMsg{Gen: m.Generation, Err: refusal})
	if m.Saving {
		t.Fatal("a refused save left the screen saving")
	}
	if m.Form == nil || m.Form.value() != "10" {
		t.Fatal("the refused value was dropped instead of kept for another try")
	}
}

// Validation the form can do itself keeps a typo from reaching the daemon.
func TestConfigFormRefusesWhatTheKindCannotTake(t *testing.T) {
	requests := 0
	conn := commandTestConnection(t, func(w http.ResponseWriter, _ *http.Request) {
		requests++
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"detail":"refused"}`))
	})
	for _, test := range []struct {
		name string
		row  int
		text string
	}{
		{"not a number", 1, "lots"},
		{"out of range", 1, "100"},
		{"blank text", 0, ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			m := loadedConfigPage(t, conn)
			for range test.row {
				m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
			}
			m, _ = m.Update(configKeyPress('e', tea.ModCtrl))
			m.Form.Inputs[configFieldValue].SetValue(test.text)
			m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
			if cmd != nil || m.Saving {
				t.Fatal("an invalid value was sent to the daemon")
			}
			if m.Error == "" {
				t.Fatal("an invalid value was refused without saying so")
			}
			if m.Form == nil {
				t.Fatal("an invalid value closed the form")
			}
		})
	}
	if requests != 0 {
		t.Fatalf("the daemon was asked to check a value the form already refused: %d requests", requests)
	}
}

// A group validator that no longer matches reloads the group and says so,
// keeping the cursor where it was.
func TestConfigStaleValidatorReloadsAndKeepsTheCursor(t *testing.T) {
	requests := []string{}
	conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
		requests = append(requests, r.Method+" "+r.URL.RequestURI())
		switch r.Method {
		case http.MethodGet:
			w.Header().Set("ETag", `"settings-b"`)
			_ = json.NewEncoder(w).Encode(protocolDeclaredGroup(72))
		default:
			if match := r.Header.Get("If-Match"); match != `"settings-b"` {
				t.Errorf("save sent If-Match %q, want the validator the read observed", match)
			}
			w.WriteHeader(http.StatusPreconditionFailed)
			_, _ = w.Write([]byte(`{"type":"about:blank","title":"Settings changed","status":412,"code":"precondition_failed","detail":"the settings changed since they were read"}`))
		}
	})
	m := NewConfigPageModel(conn)
	m, _ = m.Update(m.loadCmd(m.Generation)())
	if m.Loading || m.ETag != `"settings-b"` || len(m.Sections) != 2 {
		t.Fatalf("the group did not load: %+v", m)
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
	before, ok := m.highlighted()
	if !ok {
		t.Fatal("the cursor is not on a setting")
	}
	m, cmd := m.Update(configKeyPress('x', tea.ModCtrl))
	if !m.Saving || cmd == nil {
		t.Fatal("ctrl+x did not start a save")
	}
	m, cmd = m.Update(cmd())
	if !m.Loading || cmd == nil || m.Notice == "" {
		t.Fatalf("a stale validator did not reload the group with a notice: loading=%v notice=%q", m.Loading, m.Notice)
	}
	m, _ = m.Update(cmd())
	if m.Loading || m.Error != "" {
		t.Fatalf("the reload did not settle: loading=%v error=%q", m.Loading, m.Error)
	}
	after, ok := m.highlighted()
	if !ok || after.key != before.key {
		t.Fatalf("the cursor moved from %q to %q", before.key, after.key)
	}
	if len(requests) != 3 {
		t.Fatalf("requests = %v, want the read, the refused save and the reload", requests)
	}
}

// Resetting is offered only where a value is saved, and where it is saved it
// sends no value.
func TestConfigResetOnlyAppliesToASavedValue(t *testing.T) {
	m := loadedConfigPage(t, nil)
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
	m, cmd := m.Update(configKeyPress('x', tea.ModCtrl))
	if cmd == nil || !m.Saving {
		t.Fatal("ctrl+x did not reset the saved value")
	}
	m = loadedConfigPage(t, nil)
	m, cmd = m.Update(configKeyPress('x', tea.ModCtrl))
	if cmd != nil || m.Saving {
		t.Fatal("ctrl+x started a save for a setting that has no saved value")
	}
}

// protocolDeclaredGroup is the group the tests' daemon answers a read with:
// rolling's saved trigger and exa's unsaved endpoint.
func protocolDeclaredGroup(trigger int) map[string]any {
	return map[string]any{"sections": []any{
		map[string]any{"name": "rolling", "label": "Rolling summary compaction", "category": "context", "description": "Incremental summary", "problem": nil, "fields": []any{
			map[string]any{"key": "triggerPercent", "label": "Trigger", "description": "Percent of the window at which a compaction runs.", "kind": "integer", "default": 80, "minimum": 1, "maximum": 99, "value": trigger},
		}},
		map[string]any{"name": "exa", "label": "Exa web search", "category": "web_search", "description": "Search through exa", "problem": nil, "fields": []any{
			map[string]any{"key": "endpoint", "label": "Endpoint", "description": "Base URL of the exa API.", "kind": "text", "default": "https://api.exa.ai", "minimum": nil, "maximum": nil, "value": nil},
		}},
	}}
}

// A limit saves -1 for no limit and a number in range as itself; anything
// else never reaches the daemon.
func TestConfigFormEncodesALimit(t *testing.T) {
	limit := daemon.ExtensionSetting{Key: "cap", Label: "Cap", Kind: daemon.SettingLimit, Minimum: new(int64(1)), Maximum: new(int64(1000)), Default: daemon.SettingValue{Number: new(int64(3))}}
	for _, test := range []struct {
		text, want string
		refused    bool
	}{
		{"-1", "-1", false},
		{"7", "7", false},
		{"-2", "", true},
		{"unlimited", "", true},
	} {
		t.Run(test.text, func(t *testing.T) {
			f := newConfigForm("subagents", limit)
			f.Inputs[configFieldValue].SetValue(test.text)
			encoded, err := f.encoded()
			if (err != nil) != test.refused || (!test.refused && string(encoded) != test.want) {
				t.Fatalf("encoded %s, err %v; want %q, refused %v", encoded, err, test.want, test.refused)
			}
		})
	}
}
