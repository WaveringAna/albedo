// Checkpoint picking filters by typing, shows each checkpoint's detail beside
// the list, and asks before rewinding or branching with enter and esc only. E2E
// cannot see the question or the stray-key handling, so these assert the model
// directly.
package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"slices"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func treeFixture(t *testing.T) TreePickerModel {
	t.Helper()
	return loadedTree(t, NewTreePickerModel(nil, "s"))
}

func forkFixture(t *testing.T) TreePickerModel {
	t.Helper()
	return loadedTree(t, NewForkPickerModel(nil, "s"))
}

func loadedTree(t *testing.T, m TreePickerModel) TreePickerModel {
	t.Helper()
	m.SetSize(120, 30)
	m, _ = m.Update(treeLoadedMsg{Gen: m.Generation, Items: []daemon.TreeCheckpoint{
		{ID: "a", Type: "user", Preview: "fix the parser"},
		{ID: "b", Type: "assistant", Preview: "wrote the adapter tests"},
	}})
	if m.Loading || len(m.Checkpoints) != 2 {
		t.Fatal("fixture checkpoints did not load")
	}
	return m
}

func TestTreeFilterAndDetailWithoutEnter(t *testing.T) {
	m := treeFixture(t)
	for _, r := range "adapter" {
		m, _ = m.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "wrote the adapter tests") || strings.Contains(view, "fix the parser") {
		t.Fatalf("typing should filter the checkpoints:\n%s", view)
	}
	if !strings.Contains(view, "archived session") {
		t.Fatalf("the rewind detail should show beside the list without enter:\n%s", view)
	}
	if row, _ := m.highlighted(); row.key != "b" {
		t.Fatalf("the filter left %q under the cursor", row.key)
	}
}

func TestForkPickerAsksBeforeBranchingWithEnterAndEsc(t *testing.T) {
	m := forkFixture(t)
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if !m.Confirming() || !strings.Contains(ansi.Strip(m.View()), "Branch after user · fix the parser?") {
		t.Fatalf("enter should ask before branching:\n%s", ansi.Strip(m.View()))
	}
	m, cmd := m.Update(tea.KeyPressMsg{Code: 'y', Text: "y"})
	if cmd != nil || !m.Confirming() || m.Forking {
		t.Fatal("a stray key answered the branch question")
	}
	m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if cmd != nil || m.Confirming() {
		t.Fatal("esc should cancel the question, not leave the picker")
	}

	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if !m.Forking || cmd == nil {
		t.Fatal("the second enter should start the branch")
	}
}

func TestTreeForkFailureKeepsTheQuestionForRetry(t *testing.T) {
	m := forkFixture(t)
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	m, _ = m.Update(treeForkedMsg{Gen: m.Generation, Err: errors.New("branch refused")})
	view := ansi.Strip(m.View())
	if m.Forking || !m.Confirming() || !strings.Contains(view, "branch refused") || !strings.Contains(view, "retry") {
		t.Fatalf("a failed branch should keep the question open with retry:\n%s", view)
	}
}

func TestForkPickerIgnoresTheRewindKeys(t *testing.T) {
	m := forkFixture(t)
	for _, key := range "sg" {
		m, _ = m.Update(tea.KeyPressMsg{Code: key, Mod: tea.ModCtrl})
		if m.Confirming() {
			t.Fatalf("ctrl+%c asked a question in the fork picker", key)
		}
	}
	if view := ansi.Strip(m.View()); strings.Contains(view, "rewind") || !strings.Contains(view, "/fork") {
		t.Fatalf("the fork picker should not offer rewinding:\n%s", view)
	}
}

func TestTreeKeysAskTheirOwnQuestions(t *testing.T) {
	for key, want := range map[string]string{
		"enter":  `Rewind to before "fix the parser"? Everything after it moves to an archived session.`,
		"ctrl+s": `Rewind to before "fix the parser" and summarize what you leave?`,
		"ctrl+g": "Branch after user · fix the parser?",
	} {
		m := treeFixture(t)
		press := tea.KeyPressMsg{Code: tea.KeyEnter}
		if key != "enter" {
			press = tea.KeyPressMsg{Code: rune(key[len(key)-1]), Mod: tea.ModCtrl}
		}
		m, cmd := m.Update(press)
		if cmd != nil || !m.Confirming() || !strings.Contains(ansi.Strip(m.View()), want) {
			t.Fatalf("%s should ask %q:\n%s", key, want, ansi.Strip(m.View()))
		}
	}
}

// rewindServer answers the rewind route and hands the request body back.
func rewindServer(t *testing.T) (*daemon.Connection, chan map[string]any) {
	t.Helper()
	bodies := make(chan map[string]any, 1)
	conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/sessions/s/rewind" {
			t.Errorf("unexpected request %s %s", r.Method, r.URL)
		}
		var body map[string]any
		raw, _ := io.ReadAll(r.Body)
		if err := json.Unmarshal(raw, &body); err != nil {
			t.Errorf("rewind body %q: %v", raw, err)
		}
		bodies <- body
		_, _ = w.Write([]byte(`{"archive_session_id":"archive","input":"fix the parser","summary":null}`))
	})
	return conn, bodies
}

func TestRewindSendsTheCheckpointWithoutASummary(t *testing.T) {
	conn, bodies := rewindServer(t)
	m := treeFixture(t)
	m.Conn = conn
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if !m.Rewinding || m.Summarizing || cmd == nil {
		t.Fatal("the second enter should start the rewind")
	}
	done := cmd().(treeRewoundMsg)
	body := awaitCommandSignal(t, bodies)
	if body["checkpoint_id"] != "a" {
		t.Fatalf("rewound to %v", body["checkpoint_id"])
	}
	if _, asked := body["summary"]; asked {
		t.Fatalf("a plain rewind asked for a summary: %v", body)
	}
	if done.Err != nil || done.Outcome.ArchiveSessionID != "archive" || !done.Outcome.HasInput || done.Outcome.Input != "fix the parser" {
		t.Fatalf("outcome lost: %+v", done)
	}
}

func TestRewindWithSummaryAsksForOne(t *testing.T) {
	conn, bodies := rewindServer(t)
	m := treeFixture(t)
	m.Conn = conn
	m, _ = m.Update(tea.KeyPressMsg{Code: 's', Mod: tea.ModCtrl})
	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if !m.Rewinding || !m.Summarizing || cmd == nil || !strings.Contains(ansi.Strip(m.View()), "summarizing") {
		t.Fatalf("the summary rewind should show it is summarizing:\n%s", ansi.Strip(m.View()))
	}
	cmd()
	if body := awaitCommandSignal(t, bodies); body["summary"] == nil {
		t.Fatalf("no summary was asked for: %v", body)
	}
}

func TestRewindFailureStaysInThePickerAndCanBeRetried(t *testing.T) {
	m := treeFixture(t)
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	m, cmd := m.Update(treeRewoundMsg{Gen: m.Generation, Err: errors.New("session must be idle to rewind")})
	view := ansi.Strip(m.View())
	if cmd != nil || m.Rewinding || !strings.Contains(view, "session must be idle to rewind") {
		t.Fatalf("a refused rewind should say why and stay open:\n%s", view)
	}
	m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if !m.Rewinding || cmd == nil {
		t.Fatal("enter did not retry the rewind")
	}
}

func rewoundApp(t *testing.T) *AppModel {
	t.Helper()
	app := NewAppModel(daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, nil), Bootstrap{Settings: daemon.Settings{Profiles: config.Profiles{}}}, nil, "", false, nil)
	app.setChatSession(daemon.Session{ID: "s"}, false)
	app.State = AppStateTreePicker
	return app
}

func hasNotice(app *AppModel, text string) bool {
	for _, notice := range append(slices.Clone(app.Notices), app.Chat.Notices...) {
		if strings.Contains(notice.Message, text) {
			return true
		}
	}
	return false
}

func TestRewindReloadsTheSameSessionAndReturnsTheMessage(t *testing.T) {
	app := rewoundApp(t)
	updated, cmd := app.Update(TreeRewindReloadMsg{
		Session: daemon.Session{ID: "s"},
		Outcome: daemon.RewindOutcome{ArchiveSessionID: "archive-0123456789", Input: "fix the parser", HasInput: true, Summary: "tried it"},
	})
	app = updated.(*AppModel)
	if cmd == nil || app.State != AppStateChat || app.ActiveSession.ID != "s" || app.Chat.SessionID != "s" {
		t.Fatal("the rewound session was not reopened")
	}
	if app.Chat.TextArea.Value() != "fix the parser" {
		t.Fatalf("the removed message did not return to the composer: %q", app.Chat.TextArea.Value())
	}
	// The stream's first reset hydrates the chat and clears its notices, so the
	// note waits for it.
	if hasNotice(app, "archived as") {
		t.Fatal("the note came before the reset that would clear it")
	}
	updated, _ = app.Update(ChatStreamEventMsg{SessionID: "s", Generation: app.Chat.Generation, Event: daemon.StreamEvent{Type: daemon.EventReset}})
	app = updated.(*AppModel)
	if !hasNotice(app, "archived as archive-") || !hasNotice(app, "Summary added") || app.afterReset != "" {
		t.Fatal("the rewind left no note")
	}
}

func TestRewindKeepsADraftTheMessageWouldHaveReplaced(t *testing.T) {
	app := rewoundApp(t)
	app.Chat.TextArea.SetValue("half a thought")
	updated, _ := app.Update(TreeRewindReloadMsg{
		Session: daemon.Session{ID: "s"},
		Outcome: daemon.RewindOutcome{ArchiveSessionID: "archive", Input: "fix the parser", HasInput: true},
	})
	if got := updated.(*AppModel).Chat.TextArea.Value(); got != "half a thought" {
		t.Fatalf("the draft was overwritten: %q", got)
	}
}

// Typing narrows the list, so a letter an action once used must still filter.
func TestTreeFilterTakesEveryLetter(t *testing.T) {
	m := treeFixture(t)
	for _, r := range "fix the parser" {
		m, _ = m.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	if m.Confirming() || m.Rewinding || m.Forking {
		t.Fatalf("a typed letter started an action:\n%s", ansi.Strip(m.View()))
	}
	if row, _ := m.highlighted(); row.key != "a" {
		t.Fatalf("the filter left %q under the cursor", row.key)
	}
}
