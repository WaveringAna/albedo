// These regressions exercise card layout and repeated delivery inside the TUI.
package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/daemon/protocol"
	"github.com/charmbracelet/x/ansi"
)

func TestAgentCardReplacesProgressAndDeduplicatesMailAnimation(t *testing.T) {
	model := NewAgentsViewModel(nil, "parent")
	model.Width, model.Height = 80, 30
	child := model.node("child", "scout 界")
	child.parent = "parent"
	model.selected = child.id
	model.layout()
	activity := daemon.Activity{CurrentRequest: &protocol.AgentRequest{InputID: "task", Text: "map wake paths"}, LatestProgress: new("tracing delivery")}
	model.apply(daemon.AgentEvent{Type: "activity", Session: child.id, Activity: &activity})
	activity.LatestProgress = new("checking replay")
	model.apply(daemon.AgentEvent{Type: "activity", Session: child.id, Activity: &activity})
	view := ansi.Strip(model.View())
	if !strings.Contains(view, "map wake paths") || !strings.Contains(view, "checking replay") || strings.Contains(view, "tracing delivery") {
		t.Fatalf("narrow card did not show current request and progress: %s", view)
	}
	for _, row := range strings.Split(model.View(), "\n") {
		if ansi.StringWidth(row) > model.Width {
			t.Fatalf("card overflowed terminal width: %q", row)
		}
	}
	mail := daemon.AgentEvent{Type: "mail", MailID: "letter", From: "parent", To: "child", Kind: "task", Bytes: 20}
	model.apply(mail)
	packets, letters := len(model.packets), len(child.mail)
	model.apply(mail)
	if len(model.packets) != packets || len(child.mail) != letters {
		t.Fatal("a repeated letter produced another animation or mail row")
	}
	for range 300 {
		mail.MailID += "x"
		model.apply(mail)
	}
	if len(model.seenMail) != 256 {
		t.Fatal("mail identity cache grew past its bound")
	}
}
