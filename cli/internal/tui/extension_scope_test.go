// Extension scope toggling guards global defaults against accidental deletion and confirms inheritance.
// Confirmation and scope navigation states live in unexported picker model fields;
// E2E lacks a PTY harness to observe modal prompts before dispatch.
package tui

import (
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/testwire"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestExtensionsShowBothChoicesAndAskBeforeEachScope(t *testing.T) {
	m := NewExtensionPickerModel(nil, "s")
	m.SetSize(120, 30)
	m, _ = m.Update(extensionsLoadedMsg{Gen: m.Generation, Extensions: []ExtensionItem{
		{Name: "view", Enabled: true, GlobalEnabled: false, Overridden: true},
		{Name: "bash", Enabled: true, GlobalEnabled: true},
	}})
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "off  view") || !strings.Contains(view, "this session: on") || !strings.Contains(view, "follows global") && !strings.Contains(view, "its own choice") {
		t.Fatalf("the list should show the global default and this session's own choice:\n%s", view)
	}

	// Enter asks about the global default, shift+enter about this session
	// only, and esc leaves either question.
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if !m.Confirming() || !strings.Contains(ansi.Strip(m.View()), "Enable view globally?") {
		t.Fatalf("enter should ask about the global default:\n%s", ansi.Strip(m.View()))
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter, Mod: tea.ModShift})
	if !m.Confirming() || !strings.Contains(ansi.Strip(m.View()), "Disable view for this session only?") {
		t.Fatalf("shift+enter should ask about this session only:\n%s", ansi.Strip(m.View()))
	}
	// Other keys do nothing while the question is open.
	m, _ = m.Update(tea.KeyPressMsg{Code: 'y', Text: "y"})
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
	if !m.Confirming() || m.Cursor != 0 || m.Saving {
		t.Fatal("a stray key must neither answer nor move past the question")
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})

	// ctrl+x drops this session's choice, and only when it has one.
	m, _ = m.Update(tea.KeyPressMsg{Code: 'x', Mod: tea.ModCtrl})
	if !m.Confirming() || !strings.Contains(ansi.Strip(m.View()), "follow the global default") {
		t.Fatalf("ctrl+x should confirm dropping the session choice:\n%s", ansi.Strip(m.View()))
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
	m, _ = m.Update(tea.KeyPressMsg{Code: 'x', Mod: tea.ModCtrl})
	if m.Confirming() {
		t.Fatal("ctrl+x needs a session choice to drop")
	}
}

func TestExtensionsFilterByTypingAndShowDetailsWithoutEnter(t *testing.T) {
	m := NewExtensionPickerModel(nil, "s")
	m.SetSize(120, 30)
	m, _ = m.Update(extensionsLoadedMsg{Gen: m.Generation, Extensions: []ExtensionItem{
		{Name: "view", Description: "highlighted images", Plugins: []string{"tool"}},
		{Name: "bash", Description: "shell commands", Tools: []string{"run_command"}},
	}})
	for _, r := range "bsh" {
		m, _ = m.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	view := ansi.Strip(m.View())
	if m.Confirming() || strings.Contains(view, "highlighted images") && !strings.Contains(view, "bash") || !strings.Contains(view, "run_command") {
		t.Fatalf("typing should filter to bash and its details should show beside the list:\n%s", view)
	}
	if ext, _ := m.current(); ext.Name != "bash" {
		t.Fatalf("the filter left %q under the cursor", ext.Name)
	}
}

// A save can finish before reload fails. Controlled responses expose that
// ordering and ensure the view never offers a stale-validator mutation retry.
func TestExtensionEnableKeepsConfirmedSaveWhenReloadFails(t *testing.T) {
	for _, screen := range []string{"picker", "capability"} {
		for _, refusal := range []string{"outcome", "http"} {
			t.Run(screen+"/"+refusal, func(t *testing.T) {
				saves, reloads := 0, 0
				failureNotice := "reload cannot apply"
				if refusal == "http" {
					failureNotice = "reload not confirmed:"
				}
				session := protocolSession("s", generationA, 0)
				resource := session["configuration_resource"].(map[string]any)
				resource["etag"] = "\"saved\""
				candidate := protocolCandidate("skills", "Skills", true)
				candidate["kind"] = "extension"
				conn := commandTestConnection(t, func(w http.ResponseWriter, request *http.Request) {
					var body any
					switch {
					case request.Method == http.MethodPatch:
						saves++
						if request.URL.RequestURI() != "/sessions/s?view=configuration" || request.Header.Get("If-Match") != "\"observed\"" {
							t.Fatalf("wrong desired write %s, validator %q", request.URL, request.Header.Get("If-Match"))
						}
						body = map[string]any{"resource": resource, "session": session, "move": nil}
					case request.Method == http.MethodPost:
						reloads++
						var reload daemon.ReloadRequest
						if request.URL.Path != "/sessions/s/reload" || json.NewDecoder(request.Body).Decode(&reload) != nil || reload.Target != "session" {
							t.Fatal("enable did not issue a typed session reload")
						}
						if refusal == "http" {
							w.WriteHeader(http.StatusServiceUnavailable)
							body = map[string]any{"type": "about:blank", "title": "Reload unavailable", "status": 503, "code": "reload_unavailable", "detail": "reload cannot apply"}
						} else {
							body = map[string]any{"session": map[string]any{"state": "failed", "loaded_revision": nil, "restart_required": false, "warnings": []any{}, "failure": map[string]any{"code": "composition_unavailable", "detail": "reload cannot apply"}}, "models": []any{}, "cache_policy": nil}
						}
					case request.URL.Path == "/sessions/s/catalog":
						body = map[string]any{"discovery": map[string]any{"workspace": "/work", "revision": "fresh", "candidates": []any{candidate}, "diagnostics": []any{}, "next": nil}, "discovery_failure": nil, "loaded": map[string]any{"revision": nil, "commands": []any{}, "next": nil}}
					case request.URL.Path == "/sessions/s":
						w.Header().Set("ETag", "\"saved\"")
						body = resource["value"]
					case request.URL.Path == "/settings":
						body = testwire.Settings()
					default:
						t.Fatalf("unexpected request %s %s", request.Method, request.URL)
					}
					_ = json.NewEncoder(w).Encode(body)
				})
				if screen == "picker" {
					model := NewExtensionPickerModel(conn, "s")
					model.Loading, model.Saving = false, true
					model.confirm.ask(scopeSession, "skills", "enable", "Enable skills?")
					model.Extensions = []ExtensionItem{{Name: "skills", SessionETag: "\"observed\""}}
					message := model.changeExtensionCmd("skills", "session", true, model.Generation)()
					model, _ = model.Update(message)
					if model.Saving || model.Confirming() || model.Error != "" || len(model.Extensions) != 1 || !model.Extensions[0].Enabled || model.Extensions[0].SessionETag != "\"saved\"" || !strings.Contains(model.Notice, "Selection saved;") || !strings.Contains(model.Notice, failureNotice) {
						t.Fatalf("confirmed save was lost after reload failed: %+v", model)
					}
				} else {
					model := NewCapabilityPageModel(conn, "s", "skills")
					model.Loading, model.Saving, model.SessionETag = false, true, "\"observed\""
					message := model.enableExtensionCmd(model.Generation)()
					model, command := model.Update(message)
					if model.Saving || !model.Loading || model.Error != "" || command == nil || !strings.Contains(model.Notice, "Extension enabled;") || !strings.Contains(model.Notice, failureNotice) {
						t.Fatalf("extension save was lost after reload failed: %+v", model)
					}
					for _, next := range command().(tea.BatchMsg) {
						message := next()
						if _, loaded := message.(capabilityLoadedMsg); loaded {
							model, _ = model.Update(message)
						}
					}
					if model.Loading || !model.ExtensionEnabled || model.SessionETag != "\"saved\"" {
						t.Fatal("failed reload left stale desired selection or validator")
					}
				}
				if saves != 1 || reloads != 1 {
					t.Fatalf("save/reload were replayed: %d/%d", saves, reloads)
				}
			})
		}
	}
}
