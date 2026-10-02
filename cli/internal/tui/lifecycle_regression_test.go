// Screen replacement and modal races depend on command delivery order, which
// daemon E2E cannot control. These tests drive the actual Bubble Tea models.
package tui

import (
	"albedo/cli/internal/daemon"
	"errors"
	"strings"
	"testing"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
)

func TestReopenedScreensRejectPreviousRequestReplies(t *testing.T) {
	for _, replyErr := range []error{nil, errors.New("discarded request failed")} {
		t.Run("page", func(t *testing.T) {
			old := NewPageViewModel(nil, "s", "/notes")
			old, _ = old.Update(pageLoadedMsg{Gen: old.Generation, Err: errors.New("retry")})
			old, _ = old.Update(tea.KeyPressMsg{Code: 'r', Text: "r"})
			current := NewPageViewModel(nil, "s", "/notes")
			current, cmd := current.Update(pageLoadedMsg{Gen: old.Generation, Err: replyErr, Doc: &PageDocument{Title: "obsolete"}})
			if !current.Busy || current.Doc != nil || current.Error != "" || cmd != nil {
				t.Fatal("old load changed reopened page")
			}
			current, cmd = current.Update(pageActionExecutedMsg{Gen: old.Generation, Err: replyErr})
			if !current.Busy || current.Error != "" || cmd != nil {
				t.Fatal("old action completed reopened page")
			}
			current, _ = current.Update(pageLoadedMsg{Gen: current.Generation, Doc: &PageDocument{Title: "current"}})
			if current.Busy || current.Doc.Title != "current" {
				t.Fatal("current load was rejected")
			}
		})
		t.Run("extensions", func(t *testing.T) {
			old := NewExtensionPickerModel(nil, "s")
			old, _ = old.Update(extensionsLoadedMsg{Gen: old.Generation, Err: errors.New("retry")})
			old, _ = old.Update(tea.KeyPressMsg{Code: 'r', Text: "r"})
			current := NewExtensionPickerModel(nil, "s")
			current.Saving = true
			current, _ = current.Update(extensionsLoadedMsg{Gen: old.Generation, Err: replyErr, Extensions: []ExtensionItem{{Name: "obsolete"}}})
			current, cmd := current.Update(extensionToggledMsg{Gen: old.Generation, Err: replyErr})
			if !current.Loading || !current.Saving || len(current.Extensions) != 0 || current.Error != "" || cmd != nil {
				t.Fatal("old reply changed reopened extensions")
			}
		})
		t.Run("tree", func(t *testing.T) {
			old := NewTreePickerModel(nil, "s")
			old, _ = old.loadPage(10)
			current := NewTreePickerModel(nil, "s")
			current.Forking = true
			current, _ = current.Update(treeLoadedMsg{Gen: old.Generation, Err: replyErr})
			current, cmd := current.Update(treeForkedMsg{Gen: old.Generation, Err: replyErr})
			if !current.Loading || !current.Forking || current.Error != "" || current.ForkError != "" || cmd != nil {
				t.Fatal("old reply changed reopened tree")
			}
		})
		t.Run("context", func(t *testing.T) {
			old := NewContextInspectorModel(nil, "s")
			old, _ = old.Update(tea.KeyPressMsg{Code: 'r', Text: "r"})
			current := NewContextInspectorModel(nil, "s")
			current.Detail = &ContextDetail{Section: ContextSection{ID: "history"}}
			current, _ = current.Update(contextSnapshotLoadedMsg{Gen: old.Generation, Err: replyErr, Snapshot: &ContextSnapshot{State: "ready"}})
			current, _ = current.Update(contextPageLoadedMsg{Gen: old.Generation, Err: replyErr, SectionID: "history", Data: &ContextPage{Content: "obsolete"}})
			if !current.Loading || current.Snapshot != nil || current.Error != "" || current.Detail.Value != nil || current.Detail.Error != "" {
				t.Fatal("old reply changed reopened context")
			}
		})
		t.Run("webhooks", func(t *testing.T) {
			old := NewWebhooksPageModel(nil, "s")
			old.Loading = false
			old, _ = old.Update(tea.KeyPressMsg{Code: 'r', Text: "r"})
			current := NewWebhooksPageModel(nil, "s")
			current.Saving = true
			current, _ = current.Update(webhooksLoadedMsg{Gen: old.Generation, Err: replyErr})
			current, cmd := current.Update(webhooksSavedMsg{Gen: old.Generation, Err: replyErr, Notice: "obsolete"})
			if !current.Loading || !current.Saving || current.Error != "" || current.Notice != "" || cmd != nil {
				t.Fatal("old reply changed reopened webhooks")
			}
		})
	}
}

func TestPageFocusedInputReceivesPasteAndCursorCommands(t *testing.T) {
	for _, inputKind := range []string{"text", "secret"} {
		t.Run(inputKind, func(t *testing.T) {
			page := NewPageViewModel(nil, "s", "/notes")
			page.Busy = false
			page.Doc = &PageDocument{Actions: []PageAction{{Key: "e", Label: "edit", Input: inputKind}}}
			styles := page.TextInput.Styles()
			styles.Cursor.Blink = true
			page.TextInput.SetStyles(styles)
			page, _ = page.Update(tea.KeyPressMsg{Code: 'e', Text: "e"})
			page, _ = page.Update(tea.PasteMsg{Content: "pasted value"})
			if page.TextInput.Value() != "pasted value" {
				t.Fatal("bracketed paste was lost")
			}
			if inputKind == "secret" && strings.Contains(page.View(), "pasted value") {
				t.Fatal("pasted secret appeared in view")
			}
			page, cmd := page.Update(textinput.Blink())
			if cmd == nil {
				t.Fatal("input cursor command was dropped")
			}
			page, _ = page.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
			page, _ = page.Update(tea.PasteMsg{Content: "ignored"})
			if page.TextInput.Value() != "pasted value" {
				t.Fatal("browse mode accepted paste")
			}
		})
	}
}

func TestChatHistoryAndWindowCompletionsSurviveModal(t *testing.T) {
	conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, nil)
	session := &daemon.Session{ID: "s"}
	chat := NewChatModel(session, daemon.NewChatClient(conn, "s"))
	defer chat.Close()
	chat.SetSize(80, 24)
	chat.loadingOlder = true
	model := AppModel{ActiveSession: session, Chat: chat, State: AppStateContextInspector}
	updated, _ := model.Update(ChatOlderLoadedMsg{SessionID: "other", Generation: chat.Generation, Page: &daemon.HistoryPage{}})
	model = updated.(AppModel)
	if !model.Chat.loadingOlder {
		t.Fatal("another session completed the active history request")
	}
	updated, _ = model.Update(ChatOlderLoadedMsg{SessionID: "s", Generation: chat.Generation - 1, Page: &daemon.HistoryPage{}})
	model = updated.(AppModel)
	if !model.Chat.loadingOlder {
		t.Fatal("stale generation completed the active history request")
	}
	updated, _ = model.Update(ChatOlderLoadedMsg{SessionID: "s", Generation: chat.Generation, Page: &daemon.HistoryPage{Before: 10, More: true}})
	model = updated.(AppModel)
	if model.Chat.loadingOlder || !model.Chat.olderMore {
		t.Fatal("modal lost history completion")
	}
	tokens := 123456
	updated, _ = model.Update(ChatWindowMsg{SessionID: "s", Generation: chat.Generation, Model: "model", Tokens: &tokens})
	model = updated.(AppModel)
	if model.Chat.window == nil || *model.Chat.window != tokens {
		t.Fatal("modal lost context window completion")
	}
	model.Chat.Follow = false
	if model.Chat.loadOlder() == nil || !model.Chat.loadingOlder {
		t.Fatal("paging stayed stuck after modal completion")
	}
}

func TestDelayedForkCompletionCannotReplaceReopenedTree(t *testing.T) {
	old := NewTreePickerModel(nil, "s")
	old.Forking = true
	old, cmd := old.Update(treeForkedMsg{Gen: old.Generation, Session: daemon.Session{ID: "fork"}})
	if old.Forking || cmd == nil {
		t.Fatal("current fork did not complete")
	}
	model := AppModel{State: AppStateTreePicker, TreePicker: NewTreePickerModel(nil, "s"), ActiveSession: &daemon.Session{ID: "s"}}
	updated, next := model.Update(cmd())
	model = updated.(AppModel)
	if model.ActiveSession.ID != "s" || next != nil {
		t.Fatal("discarded tree completion changed session")
	}
}
