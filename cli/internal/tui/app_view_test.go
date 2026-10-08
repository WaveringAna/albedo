// The daemon e2e checks rendered views for leaked row marks. These tests also
// check byte-for-byte preservation of terminal sequences and internal hit targets.
package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	"github.com/charmbracelet/x/ansi"
)

func TestAppViewKeepsRowMarksInternal(t *testing.T) {
	chat := newTestChatModel(t, &daemon.Session{ID: "s"})
	chat.SetSize(80, 24)
	chat.appendSettledEntry(HistoryEntry{Kind: EntryUser, Text: "hi", Timestamp: 1})
	chat.appendSettledEntry(HistoryEntry{Kind: EntryAssistant, Text: "a reply to copy", Timestamp: 2})
	chat.appendSettledEntry(HistoryEntry{Kind: EntryTurnEnd, Mood: moodDone, Timestamp: 3})
	chat.refreshViewportContent()
	app := &AppModel{State: AppStateChat, Chat: chat}
	internal := app.content()
	if !strings.Contains(internal, markChrome) {
		t.Fatal("fixture has no row marks")
	}
	view := app.View().Content
	if strings.Contains(view, "\x1b_albedo:") {
		t.Fatalf("private row marks reached the terminal: %q", view)
	}
	if ansi.Strip(view) != ansi.Strip(internal) {
		t.Fatal("removing row marks changed visible content")
	}
	if app.content() != internal {
		t.Fatal("drawing removed the internal selection and click metadata")
	}
}

func TestPrivateRowMarksPreserveTerminalSequences(t *testing.T) {
	terminal := "\x1b[31mred\x1b[0m" +
		"\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\" +
		"\x1b_Ga=T;AAAA\x1b\\"
	for _, mark := range []string{
		markChrome, markWrap, markSplit,
		(rowAction{verbCopy, "1-ab"}).mark(),
		(rowAction{verbOpen, "1-ab"}).mark(),
		(rowAction{verbMore, "1-ab"}).mark(),
	} {
		if got := privateRowMarks.ReplaceAllString(mark+terminal+mark, ""); got != terminal {
			t.Fatalf("mark %q: changed terminal sequences: %q", mark, got)
		}
	}
}
