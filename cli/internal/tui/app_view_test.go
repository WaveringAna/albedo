// The daemon e2e checks rendered views for leaked row marks. These tests also
// check byte-for-byte preservation of terminal sequences, that the rows the
// chat keeps for hit testing still carry their marks, and that focus reporting
// is asked of the terminal.
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
	rows := strings.Join(app.Chat.frameLines, "\n")
	if !strings.Contains(rows, markChrome) {
		t.Fatal("fixture has no row marks")
	}
	view := app.View().Content
	if strings.Contains(view, markPrefix) {
		t.Fatalf("private row marks reached the terminal: %q", view)
	}
	// every row the chat keeps for clicks and selection shows its text intact
	for _, row := range app.Chat.frameLines {
		if plain := stripPrivateMarks(row); plain != "" && !strings.Contains(view, plain) {
			t.Fatalf("row %q never reached the terminal", plain)
		}
	}
	if after := strings.Join(app.Chat.frameLines, "\n"); after != rows {
		t.Fatal("drawing removed the internal selection and click metadata")
	}
	if !strings.Contains(ansi.Strip(view), "a reply to copy") {
		t.Fatalf("the transcript is missing from the frame:\n%s", view)
	}
}

func TestAppViewReportsFocus(t *testing.T) {
	app := &AppModel{State: AppStateChat, Chat: newTestChatModel(t, &daemon.Session{ID: "s"})}
	app.Chat.SetSize(80, 24)
	if !app.View().ReportFocus {
		t.Fatal("the client never hears that its terminal lost focus")
	}
	app.State = AppStateQuota
	if !app.View().ReportFocus {
		t.Fatal("focus reporting is only asked for in chat")
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
		if got := stripPrivateMarks(mark + terminal + mark); got != terminal {
			t.Fatalf("mark %q: changed terminal sequences: %q", mark, got)
		}
	}
}

func TestStripPrivateMarksLeavesWhatIsNotAMark(t *testing.T) {
	for _, text := range []string{
		"",                                     // nothing at all
		"plain rows",                           // no marks
		markPrefix + "unterminated",            // a mark with no terminator
		markPrefix + "an \x1b[0m escape\x1b\\", // an escape inside the payload
		"\x1b[31m" + markChrome + "\x1b[0m",    // a mark between styles
	} {
		want := text
		if text == "\x1b[31m"+markChrome+"\x1b[0m" {
			want = "\x1b[31m\x1b[0m"
		}
		if got := stripPrivateMarks(text); got != want {
			t.Fatalf("stripPrivateMarks(%q) = %q, want %q", text, got, want)
		}
	}
}
