// These regressions exercise event ordering and row identity inside the TUI,
// which daemon E2E cannot inspect or deliver twice at a chosen boundary.
package tui

import (
	"testing"

	"albedo/cli/internal/daemon"
)

func TestEmptyProviderRecordsDoNotDuplicateStreamedReply(t *testing.T) {
	for _, settled := range []bool{false, true} {
		model := newTestChatModel(t, &daemon.Session{ID: "parent"})
		model.SetSize(120, 30)
		model.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventUser, Text: "launch a child", Source: "chat"})
		reply := "Launched a subagent to write the Python love song."
		model.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventText, Text: reply})
		if settled {
			model.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventUsage})
		}
		for _, id := range []string{"2-provider", "3-provider"} {
			model.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventMessage, EntryID: id})
		}
		final := daemon.StreamEvent{Type: daemon.EventMessage, EntryID: "4", Position: 4, Text: reply}
		model.handleStreamEvent(final)
		model.handleStreamEvent(final)
		model.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventTurnCompleted})
		count, footers := 0, 0
		for _, entry := range model.History.Entries() {
			if entry.Kind == EntryAssistant {
				if entry.Text != reply || entry.ID != "4" {
					t.Fatalf("wrong saved reply: %#v", entry)
				}
				count++
			}
			if entry.Kind == EntryTurnEnd {
				footers++
			}
		}
		if count != 1 || footers != 1 {
			t.Fatalf("settled=%v: got %d replies and %d footers", settled, count, footers)
		}
	}
}

func TestMailIdentityPreservesDistinctMessagesAndTurnOwnership(t *testing.T) {
	model := newTestChatModel(t, &daemon.Session{ID: "parent"})
	model.SetSize(100, 30)
	model.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventUser, Source: "chat", Text: "start"})
	model.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventText, Text: "working"})
	turn := model.transcript.turn
	mail := daemon.StreamEvent{Type: daemon.EventUser, Source: "mail", Speaker: "You", MailKind: "result", EntryID: "7", Position: 7, Text: "finished"}
	model.handleStreamEvent(mail)
	if model.transcript.turn != turn {
		t.Fatal("a sender named You reopened the parent's turn")
	}
	model.handleStreamEvent(mail)
	mail.Text = "finished with evidence"
	model.handleStreamEvent(mail)
	mail.EntryID, mail.Position = "8", 8
	model.handleStreamEvent(mail)
	count := 0
	for _, entry := range model.History.Entries() {
		if entry.Source == "mail" {
			count++
			if entry.Speaker != "You" || entry.Text != mail.Text {
				t.Fatalf("mail update lost attribution: %#v", entry)
			}
		}
	}
	if count != 2 {
		t.Fatalf("distinct identical letters must remain distinct, got %d", count)
	}
	model.loadingOlder = true
	model.showOlder(ChatOlderLoadedMsg{SessionID: model.SessionID, Generation: model.Generation, Page: &daemon.HistoryPage{Events: []daemon.StreamEvent{mail}, Before: 8}})
	if model.History.Len() != 4 {
		t.Fatalf("overlapping history added rows: %#v", model.History.Entries())
	}
	model.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventReset})
	mail.Replayed = true
	model.handleStreamEvent(mail)
	if model.History.Len() != 1 || model.History.Entries()[0].Speaker != "You" {
		t.Fatal("reset failed to replace the transcript with attributed history")
	}
}
