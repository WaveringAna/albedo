package e2e

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui"
	tea "charm.land/bubbletea/v2"
)

func pastedLines(label string, count int) string {
	lines := make([]string, count)
	for i := range lines {
		lines[i] = fmt.Sprintf("%s line %d", label, i)
	}
	return strings.Join(lines, "\n")
}

func TestTUIPastesAndImagesBecomeMarkersTheModelReceivesInPlace(t *testing.T) {
	profile := providerRoute(t, echoReply)
	t.Parallel()
	driver := newTUIDriver(t)
	t.Cleanup(func() { driver.App.Chat.Close() })
	driver.connected()
	chat := func() *tui.ChatModel { return &driver.App.Chat }

	logs := pastedLines("log", 30)
	driver.Type("first ")
	driver.Update(tea.PasteMsg{Content: logs})
	driver.Update(tea.PasteMsg{Content: pastedLines("dropped", 12)})
	if got := chat().TextArea.Value(); got != "first [Paste #1, +30 lines][Paste #2, +12 lines]" {
		t.Fatalf("pastes did not collapse into markers: %q", got)
	}
	driver.Update(tea.KeyPressMsg{Code: tea.KeyBackspace})
	if got := chat().TextArea.Value(); got != "first [Paste #1, +30 lines]" {
		t.Fatalf("one backspace did not remove the whole marker: %q", got)
	}
	driver.pasteImage(&daemon.ImageAttachment{Data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC", ImageMetadata: daemon.ImageMetadata{MimeType: daemon.ImagePNG, Width: 1, Height: 1, Bytes: 69}})
	driver.Type(" end")
	view := driver.View()
	for _, want := range []string{"paste #1", "+30 lines", "log line 0", "image #1", "1×1"} {
		if !strings.Contains(view, want) {
			t.Fatalf("the attachment strip lacks %q:\n%s", want, view)
		}
	}

	var sent tui.ChatTurnSentMsg
	for _, message := range driver.results(driver.Update(tea.KeyPressMsg{Code: tea.KeyEnter})) {
		if result, ok := message.(tui.ChatTurnSentMsg); ok {
			sent = result
		}
		driver.Update(message)
	}
	if sent.Err != nil || sent.Prompt != "first [Paste #1, +30 lines][Image #1] end" || len(sent.Pastes) != 1 || len(sent.Images) != 1 {
		t.Fatalf("submission lost its attachments: %+v", sent)
	}
	waitIdle(t, chat().SessionID, profile, 1)
	requests := suite.provider.requests(profile)
	body, _ := json.Marshal(requests[len(requests)-1])
	want, _ := json.Marshal("first " + logs + "[Image #1] end")
	if !strings.Contains(string(body), string(want)) {
		t.Fatalf("the model did not receive the paste in place:\n%s", body)
	}
}
