//go:build unix

// Slash shortcuts must change the same real resources as their page actions,
// retaining workspace boundaries, observed validators, and delete confirmation.
package e2e

import (
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/daemon/protocol"
	"albedo/cli/internal/tui"

	tea "charm.land/bubbletea/v2"
)

func executeShortcut(t *testing.T, session, command, arguments string) daemon.CommandResult {
	t.Helper()
	prepared, err := daemon.PreparePageShortcut(t.Context(), conn(t), session, command, arguments)
	if err != nil {
		t.Fatalf("prepare %s %s: %v", command, arguments, err)
	}
	result, err := daemon.ExecutePageAction(t.Context(), conn(t), prepared.Request)
	if err != nil {
		t.Fatalf("execute %s %s: %v", command, arguments, err)
	}
	return result
}

func shortcutWorkItem(t *testing.T, result daemon.CommandResult) protocol.WorkItem {
	t.Helper()
	var changed protocol.WorkChange
	if err := json.Unmarshal(result.Result, &changed); err != nil || changed.Resource.Value.ID == "" {
		t.Fatalf("work change: %s, %v", result.Result, err)
	}
	return changed.Resource.Value
}

func shortcutPaperclip(t *testing.T, result daemon.CommandResult) protocol.Paperclip {
	t.Helper()
	var changed protocol.PaperclipChange
	if err := json.Unmarshal(result.Result, &changed); err != nil || changed.Resource.Value.ID == "" {
		t.Fatalf("paperclip change: %s, %v", result.Result, err)
	}
	return changed.Resource.Value
}

func createShortcutPaperclip(t *testing.T, session string) protocol.Paperclip {
	t.Helper()
	page, err := daemon.LoadPage(t.Context(), conn(t), session, "/paperclips")
	if err != nil {
		t.Fatal(err)
	}
	index := slices.IndexFunc(page.Actions, func(action daemon.PageAction) bool { return action.ID == "create" })
	if index < 0 {
		t.Fatal("paperclips page has no create action")
	}
	result, err := daemon.ExecutePageAction(t.Context(), conn(t), daemon.PageActionRequest{
		Action: page.Actions[index], Session: page.Session,
		Form: map[string]json.RawMessage{"message": json.RawMessage(`"shortcut fixture"`)},
	})
	if err != nil {
		t.Fatal(err)
	}
	return shortcutPaperclip(t, result)
}

func TestWorkShortcutsPreserveOtherFieldsAndWorkspaceScope(t *testing.T) {
	providerRoute(t, echoReply)
	t.Parallel()
	session := newSession(t, t.TempDir())
	item := shortcutWorkItem(t, executeShortcut(t, session, "/work", "add a multiword title"))
	if item.Title != "a multiword title" || item.Status != "open" {
		t.Fatalf("add shortcut changed the wrong fields: %+v", item)
	}
	prepared, err := daemon.PreparePageShortcut(t.Context(), conn(t), session, "/work", "edit "+item.ID+" revised title")
	if err != nil {
		t.Fatal(err)
	}
	prepared.Request.Form["notes"] = json.RawMessage(`"keep these notes"`)
	result, err := daemon.ExecutePageAction(t.Context(), conn(t), prepared.Request)
	if err != nil {
		t.Fatal(err)
	}
	item = shortcutWorkItem(t, result)
	if item.Title != "revised title" || item.Notes != "keep these notes" {
		t.Fatalf("edit shortcut: %+v", item)
	}
	item = shortcutWorkItem(t, executeShortcut(t, session, "/work", "status "+item.ID+" blocked"))
	if item.Status != "blocked" || item.Title != "revised title" || item.Notes != "keep these notes" {
		t.Fatalf("status shortcut lost the other fields: %+v", item)
	}
	item = shortcutWorkItem(t, executeShortcut(t, session, "/work", "edit "+item.ID+" final title"))
	if item.Title != "final title" || item.Status != "blocked" || item.Notes != "keep these notes" {
		t.Fatalf("title shortcut lost the other fields: %+v", item)
	}
	other := newSession(t, t.TempDir())
	_, err = daemon.PreparePageShortcut(t.Context(), conn(t), other, "/work", "edit "+item.ID+" crossed workspace")
	problem, ok := errors.AsType[*daemon.APIError](err)
	if !ok || problem.StatusCode != http.StatusNotFound {
		t.Fatalf("shortcut reached another workspace's item: %v", err)
	}
	unchanged, err := daemon.PreparePageShortcut(t.Context(), conn(t), session, "/work", "edit "+item.ID+" untouched")
	if err != nil || unchanged.Request.Row.Text != "final title" {
		t.Fatalf("foreign workspace shortcut changed the item: %+v, %v", unchanged, err)
	}
	if status := daemonSession(t, session).Status; status.KernelInstanceID != nil {
		t.Fatalf("HTTP page shortcuts opened a kernel: %+v", status)
	}
}

func TestPaperclipShortcutsApplyDeclaredStatusAndReplyActions(t *testing.T) {
	providerRoute(t, echoReply)
	t.Parallel()
	session := newSession(t, t.TempDir())
	item := createShortcutPaperclip(t, session)
	for _, scenario := range []struct {
		arguments, status, reply, resolution string
	}{
		{"acknowledge " + item.ID, "acknowledged", "", ""},
		{"reply " + item.ID + " a multiword reply", "acknowledged", "a multiword reply", ""},
		{"resolve " + item.ID + " a multiword resolution", "resolved", "a multiword reply", "a multiword resolution"},
		{"dismiss " + item.ID, "dismissed", "a multiword reply", "a multiword resolution"},
		{"resolve " + item.ID, "resolved", "a multiword reply", "a multiword resolution"},
	} {
		item = shortcutPaperclip(t, executeShortcut(t, session, "/paperclips", scenario.arguments))
		if item.Status != scenario.status || item.Reply != scenario.reply || item.Resolution != scenario.resolution {
			t.Fatalf("%s changed the wrong fields: %+v", scenario.arguments, item)
		}
	}
}

func TestPageShortcutsRejectInvalidArgumentsWithoutChangingResources(t *testing.T) {
	providerRoute(t, echoReply)
	t.Parallel()
	session := newSession(t, t.TempDir())
	work := shortcutWorkItem(t, executeShortcut(t, session, "/work", "add unchanged work"))
	clip := createShortcutPaperclip(t, session)
	for _, scenario := range []struct{ command, arguments string }{
		{"/work", "add"},
		{"/work", "edit"},
		{"/work", "edit 0 title"},
		{"/work", "edit invalid title"},
		{"/work", "status " + work.ID},
		{"/work", "status " + work.ID + " unsupported"},
		{"/work", "remove " + work.ID + " extra"},
		{"/work", "unknown " + work.ID},
		{"/paperclips", "reply " + clip.ID},
		{"/paperclips", "acknowledge"},
		{"/paperclips", "dismiss " + clip.ID + " extra"},
		{"/paperclips", "remove -1"},
	} {
		if _, err := daemon.PreparePageShortcut(t.Context(), conn(t), session, scenario.command, scenario.arguments); err == nil {
			t.Fatalf("accepted invalid shortcut %s %s", scenario.command, scenario.arguments)
		}
	}
	for _, scenario := range []struct{ command, arguments, title, badge string }{
		{"/work", "edit " + work.ID + " unsubmitted", "unchanged work", "open"},
		{"/paperclips", "acknowledge " + clip.ID, "shortcut fixture", "open"},
	} {
		prepared, err := daemon.PreparePageShortcut(t.Context(), conn(t), session, scenario.command, scenario.arguments)
		if err != nil || prepared.Request.Row.Text != scenario.title || prepared.Request.Row.Badge != scenario.badge {
			t.Fatalf("invalid arguments changed a resource: %+v, %v", prepared, err)
		}
	}
}

func TestWorkShortcutFindsOffPageTargetAndRejectsStaleValidator(t *testing.T) {
	providerRoute(t, echoReply)
	t.Parallel()
	session := newSession(t, t.TempDir())
	creation, err := daemon.PreparePageShortcut(t.Context(), conn(t), session, "/work", "add paginated fixture")
	if err != nil {
		t.Fatal(err)
	}
	var target protocol.WorkItem
	for range 51 {
		result, err := daemon.ExecutePageAction(t.Context(), conn(t), creation.Request)
		if err != nil {
			t.Fatal(err)
		}
		target = shortcutWorkItem(t, result)
	}
	page, err := daemon.LoadPage(t.Context(), conn(t), session, "/work")
	if err != nil {
		t.Fatal(err)
	}
	if slices.ContainsFunc(page.Rows, func(row daemon.PageRow) bool { return row.ID == target.ID }) {
		t.Fatal("fixture did not place its target beyond the first page")
	}
	stale, err := daemon.PreparePageShortcut(t.Context(), conn(t), session, "/work", "edit "+target.ID+" stale title")
	if err != nil || stale.Request.Row.ID != target.ID || !slices.ContainsFunc(stale.Page.Rows, func(row daemon.PageRow) bool { return row.ID == target.ID }) {
		t.Fatalf("off-page target was not captured: %+v, %v", stale, err)
	}
	target = shortcutWorkItem(t, executeShortcut(t, session, "/work", "edit "+target.ID+" newer title"))
	_, err = daemon.ExecutePageAction(t.Context(), conn(t), stale.Request)
	problem, ok := errors.AsType[*daemon.APIError](err)
	if !ok || problem.StatusCode != http.StatusPreconditionFailed {
		t.Fatalf("stale shortcut overwrote a newer edit: %v", err)
	}
	current, err := daemon.PreparePageShortcut(t.Context(), conn(t), session, "/work", "edit "+target.ID+" unsubmitted")
	if err != nil || current.Request.Row.Text != "newer title" {
		t.Fatalf("stale edit changed the item: %+v, %v", current, err)
	}
}

func TestTUIPageRemoveShortcutConfirmsOrCancels(t *testing.T) {
	providerRoute(t, echoReply)
	t.Parallel()
	session := daemonSession(t, newSession(t, t.TempDir()))
	driver := driveTUI(t, &session)
	t.Cleanup(func() { driver.App.Chat.Close() })
	driver.connected()
	commands, err := daemon.ListSessionCommands(t.Context(), conn(t), session.ID)
	if err != nil {
		t.Fatal(err)
	}
	driver.App.Chat.CommandMenu.Catalog = commands
	driver.App.Chat.TextArea.SetValue("/work add confirmed work removal")
	driver.Dispatch(tea.KeyPressMsg{Code: tea.KeyEnter})
	if driver.App.State != tui.AppStatePageView || driver.App.PageView.Error != "" || driver.App.PageView.Doc == nil || len(driver.App.PageView.Doc.Rows) != 1 {
		t.Fatalf("composer shortcut did not create a work item:\n%s", driver.View())
	}
	workID := driver.App.PageView.Doc.Rows[0].ID
	clip := createShortcutPaperclip(t, session.ID)
	for _, scenario := range []struct{ command, id string }{{"/work", workID}, {"/paperclips", clip.ID}} {
		remove := tui.ChatExecuteCommandMsg{Name: scenario.command, Args: "remove " + scenario.id}
		driver.Dispatch(remove)
		if driver.App.State != tui.AppStatePageView || driver.App.PageView.CurrentAction == nil || !driver.App.PageView.CurrentAction.Confirm || !strings.Contains(driver.View(), "Delete this item?") {
			t.Fatalf("remove skipped confirmation for %s:\n%s", scenario.command, driver.View())
		}
		if _, err := daemon.PreparePageShortcut(t.Context(), conn(t), session.ID, scenario.command, "remove "+scenario.id); err != nil {
			t.Fatalf("item disappeared before confirmation: %v", err)
		}
		driver.Dispatch(tea.KeyPressMsg{Code: tea.KeyEscape})
		if driver.App.PageView.CurrentAction != nil {
			t.Fatal("cancelled removal retained its action")
		}
		if _, err := daemon.PreparePageShortcut(t.Context(), conn(t), session.ID, scenario.command, "remove "+scenario.id); err != nil {
			t.Fatalf("Escape removed the item: %v", err)
		}
		driver.Dispatch(remove)
		driver.Dispatch(tea.KeyPressMsg{Code: tea.KeyEnter})
		if driver.App.PageView.Error != "" {
			t.Fatalf("confirmed removal failed: %s", driver.App.PageView.Error)
		}
		_, err := daemon.PreparePageShortcut(t.Context(), conn(t), session.ID, scenario.command, "remove "+scenario.id)
		problem, ok := errors.AsType[*daemon.APIError](err)
		if !ok || problem.StatusCode != http.StatusNotFound {
			t.Fatalf("confirmed %s item %s still exists: %v", scenario.command, scenario.id, err)
		}
	}
}
