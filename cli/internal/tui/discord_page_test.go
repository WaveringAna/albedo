// Discord screen key routing and state that the daemon e2e cannot see:
// which change a key sends and what the screen shows before the daemon
// answers, that keys meant for a row never reach the wrong row, that a stale
// poll tick or reply changes nothing, and that a typed token is never drawn.
package tui

import (
	"albedo/cli/internal/daemon"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

var (
	discordSpace  = tea.KeyPressMsg{Code: tea.KeySpace, Text: " "}
	discordEnter  = tea.KeyPressMsg{Code: tea.KeyEnter}
	discordDown   = tea.KeyPressMsg{Code: tea.KeyDown}
	discordTabKey = tea.KeyPressMsg{Code: tea.KeyTab}
	discordEsc    = tea.KeyPressMsg{Code: tea.KeyEscape}
)

func discordCtrl(r rune) tea.KeyPressMsg { return tea.KeyPressMsg{Code: r, Mod: tea.ModCtrl} }

// recordedDiscord opens the first gallery bot over a peer that records every
// change it is sent and answers it the way the daemon does.
func recordedDiscord(t *testing.T) (*DiscordPageModel, *[]string) {
	t.Helper()
	var seen []string
	conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		seen = append(seen, r.Method+" "+r.URL.Path+" "+string(body))
		switch {
		case strings.Contains(r.URL.Path, "/channels/"):
			_, _ = io.WriteString(w, `{"channel_id":"c3","delivery":"turn","mentions_only":false}`)
		case strings.Contains(r.URL.Path, "/requests/"):
			_, _ = io.WriteString(w, `{"deleted":"70351110224678914"}`)
		default:
			_, _ = io.WriteString(w, `{"user_id":"70351110224678914","name":"kestrel","added_at":1}`)
		}
	})
	m := discordOpenModel(120, 30)
	m.Conn = conn
	return &m, &seen
}

// run applies a key and the change it starts, without the reload after it.
func (m *DiscordPageModel) run(t *testing.T, key tea.Msg) {
	t.Helper()
	next, cmd := m.Update(key)
	*m = next
	if cmd == nil {
		return
	}
	if saved, ok := cmd().(discordSavedMsg); ok {
		if saved.Err != nil {
			t.Fatalf("change failed: %v", saved.Err)
		}
		saved.Reload = false
		*m, _ = m.Update(saved)
	}
}

func TestSpaceCyclesAChannelAndSendsItsWholeSetting(t *testing.T) {
	m, seen := recordedDiscord(t)
	for range 3 {
		m.run(t, discordDown)
	}
	if row, _ := m.inner.highlighted(); row.key != "c3" {
		t.Fatalf("cursor on %q, want #ideas", row.key)
	}
	m.run(t, discordSpace)
	if _, c, _ := m.channel("c3"); c.Delivery != "turn" {
		t.Fatalf("#ideas is %q after space, want turn", c.Delivery)
	}
	m.run(t, discordCtrl('t'))
	if _, c, _ := m.channel("c3"); c.Delivery != "turn" || !c.MentionsOnly {
		t.Fatalf("ctrl+t left #ideas at %+v", c)
	}
	want := []string{
		`PUT /extensions/discord/bots/b1/channels/c3 {"channel_name":"ideas","delivery":"turn","guild_id":"g1","guild_name":"albedo lab","mentions_only":false}`,
		`PUT /extensions/discord/bots/b1/channels/c3 {"channel_name":"ideas","delivery":"turn","guild_id":"g1","guild_name":"albedo lab","mentions_only":true}`,
	}
	if strings.Join(*seen, "\n") != strings.Join(want, "\n") {
		t.Fatalf("sent:\n%s", strings.Join(*seen, "\n"))
	}
	if m.inner.input.Value() != "" {
		t.Fatalf("space reached the filter: %q", m.inner.input.Value())
	}
}

func TestDMKeysOnlyActOnTheirRows(t *testing.T) {
	m, seen := recordedDiscord(t)
	m.run(t, discordTabKey)
	// The owner row: nothing removes or allows you.
	m.run(t, discordCtrl('d'))
	m.run(t, discordEnter)
	if m.Confirming() || len(*seen) != 0 {
		t.Fatalf("keys acted on the owner: confirming=%v sent=%v", m.Confirming(), *seen)
	}
	m.run(t, discordDown)
	m.run(t, discordCtrl('d'))
	if !m.Confirming() || !strings.Contains(m.confirm.prompt, "Remove niri?") {
		t.Fatalf("ctrl+d on an allowed person should ask first: %q", m.confirm.prompt)
	}
	m.run(t, discordEsc)
	if m.Confirming() || m.Open == "" {
		t.Fatal("esc should cancel only the question")
	}
	m.run(t, discordDown)
	m.run(t, discordEnter)
	m.run(t, discordCtrl('x'))
	want := []string{
		`PUT /extensions/discord/bots/b1/dms/70351110224678914 {"name":null}`,
		`DELETE /extensions/discord/bots/b1/requests/70351110224678914 `,
	}
	if strings.Join(*seen, "\n") != strings.Join(want, "\n") {
		t.Fatalf("sent:\n%s", strings.Join(*seen, "\n"))
	}
}

func TestDiscordEscLeavesTheBotBeforeTheScreen(t *testing.T) {
	m := discordOpenModel(120, 30)
	m, cmd := m.Update(discordEsc)
	if m.Open != "" || cmd != nil {
		t.Fatal("esc in a bot should go back to the bot list")
	}
	if _, cmd = m.Update(discordEsc); cmd == nil {
		t.Fatal("esc in the list should leave the screen")
	}
	if _, done := cmd().(DiscordPageDoneMsg); !done {
		t.Fatal("esc in the list should report the screen done")
	}
}

func TestDiscordPollIgnoresOtherTicksAndClearsItsOwnFailure(t *testing.T) {
	m := discordModel(120, 30, nil)
	if _, cmd := m.Update(discordTickMsg{ticker: m.ticker + 1}); cmd != nil {
		t.Fatal("a tick from an earlier screen kept polling")
	}
	m, _ = m.Update(discordLoadedMsg{Gen: m.Generation, Quiet: true, Err: errors.New("daemon went away")})
	if m.Error != "daemon went away" || len(m.Bots) != len(galleryBots) {
		t.Fatalf("a failed poll should keep the bots and say why: %q", m.Error)
	}
	bots := append([]daemon.DiscordBot(nil), galleryBots...)
	bots[1].State = "online"
	m, _ = m.Update(discordLoadedMsg{Gen: m.Generation, Quiet: true, Mounted: true, Bots: bots})
	if m.Error != "" || m.Bots[1].State != "online" {
		t.Fatalf("a good poll should clear its failure and show the new state: %q %q", m.Error, m.Bots[1].State)
	}
	if len(m.Sessions) != len(discordSessions) {
		t.Fatal("a poll without sessions dropped the session names")
	}
}

func TestDiscordFormChecksBeforeSendingAndHidesTheToken(t *testing.T) {
	m := discordModel(120, 30, nil)
	m, _ = m.Update(discordCtrl('o'))
	if m.Form == nil || m.Form.Chosen != "v" {
		t.Fatal("a new bot should default to the session the screen was opened from")
	}
	for _, r := range "albedo" {
		m, _ = m.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	m, _ = m.Update(discordTabKey)
	m, _ = m.Update(discordTabKey)
	m, _ = m.Update(tea.PasteMsg{Content: "MTEwMA.Gx-secret.part"})
	m, cmd := m.Update(discordCtrl('s'))
	if cmd != nil || !strings.Contains(m.Error, "user ID") {
		t.Fatalf("a missing owner should be refused before sending: %q", m.Error)
	}
	if strings.Contains(ansi.Strip(m.View()), "secret") {
		t.Fatal("the typed token was drawn")
	}
	m.Form.Inputs[discordFieldOwner].SetValue("80351110224678912")
	if request, err := m.Form.create(); err != nil || request.SessionID != "v" || request.Token != "MTEwMA.Gx-secret.part" {
		t.Fatalf("create = %+v, %v", request, err)
	}
}

func TestDiscordEditSendsOnlyWhatChanged(t *testing.T) {
	m := discordModel(120, 30, nil)
	m, _ = m.Update(discordCtrl('e'))
	if patch, err := m.Form.patch(); patch != nil || err != nil {
		t.Fatalf("an unchanged form produced %+v, %v", patch, err)
	}
	m.Form.Inputs[discordFieldToken].SetValue("new.token.value")
	patch, err := m.Form.patch()
	if err != nil || patch.Token == nil || patch.Name != nil || patch.OwnerID != nil || patch.Revision != galleryBots[0].Revision {
		t.Fatalf("patch = %+v, %v", patch, err)
	}
	// Editing skips the fixed session field both ways.
	m.Form.Focus = 0
	m.Form.update(discordTabKey)
	if m.Form.current() != discordFieldToken {
		t.Fatalf("tab from the name went to %q", m.Form.current())
	}
}
