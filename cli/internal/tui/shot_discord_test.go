// Gallery states of the Discord screen; TestShotGallery/discord draws them.
// Without ALBEDO_SHOT_DIR they are only built, which keeps each one buildable.
package tui

import (
	"albedo/cli/internal/daemon"
	"errors"
	"time"

	tea "charm.land/bubbletea/v2"
)

// discordSessions start with the one the screen is opened from, which has
// no bot yet, as the loader orders them.
var discordSessions = []daemon.Session{
	{ID: "v", Title: "lab assistant", Workspace: "/srv/lab"},
	{ID: "s", Title: "infra bot", Workspace: "/srv/infra"},
	{ID: "t", Title: "release notes", Workspace: "/srv/docs"},
	{ID: "u", Title: "garden", Workspace: "/srv/garden"},
}

// galleryBots are one online bot with a waiting request, one that failed to
// sign in, and one turned off.
var galleryBots = []daemon.DiscordBot{
	{ID: "b1", SessionID: "s", Name: "albedo", OwnerID: "80351110224678912", State: "online", UserID: "1100", Username: "albedo-infra", ApplicationID: "1100", Invite: "https://discord.com/oauth2/authorize?client_id=1100&scope=bot&permissions=274878024768", Revision: 3, Channels: 2, Allowed: 1, Requests: 1, Enabled: true},
	{ID: "b2", SessionID: "t", Name: "scribe", OwnerID: "80351110224678912", State: "failed", Detail: "Discord refused the token (4004 authentication failed). Reset it in the developer portal and paste the new one with ctrl+e.", Revision: 1, Enabled: true},
	{ID: "b3", SessionID: "u", Name: "gardener", OwnerID: "80351110224678912", State: "disabled", Revision: 2, Channels: 1},
}

var galleryGuilds = []daemon.DiscordGuild{{ID: "g1", Name: "albedo lab", Channels: []daemon.DiscordChannel{
	{ID: "c0", Name: "welcome", Type: 0, Position: 0, Delivery: "off"},
	{ID: "k1", Name: "Agents", Type: channelCategory, Position: 1, Delivery: "off"},
	{ID: "c1", Name: "general", Type: 0, ParentID: "k1", Position: 2, Delivery: "turn"},
	{ID: "c2", Name: "albedos", Type: 0, ParentID: "k1", Position: 3, Delivery: "tool", MentionsOnly: true},
	{ID: "c3", Name: "ideas", Type: 15, ParentID: "k1", Position: 4, Delivery: "off"},
	{ID: "k2", Name: "Voice", Type: channelCategory, Position: 5, Delivery: "off"},
	{ID: "c4", Name: "lounge", Type: 2, ParentID: "k2", Position: 6, Delivery: "off"},
}}}

var galleryDMs = daemon.DiscordDMs{
	Owner:    daemon.DiscordPerson{UserID: "80351110224678912", Name: "ana"},
	Allowed:  []daemon.DiscordPerson{{UserID: "90351110224678913", Name: "niri", AddedAt: galleryNow.Add(-50 * time.Hour).UnixMilli()}},
	Requests: []daemon.DiscordRequest{{UserID: "70351110224678914", Username: "kestrel", Preview: "hey! is this ana's albedo? mine wants to compare notes on the build", Count: 2, LastAt: galleryNow.Add(-7 * time.Minute).UnixMilli()}},
}

var galleryNow = time.Date(2026, 10, 16, 12, 0, 0, 0, time.UTC)

func init() {
	enter := tea.KeyPressMsg{Code: tea.KeyEnter}
	tab := tea.KeyPressMsg{Code: tea.KeyTab}
	down := tea.KeyPressMsg{Code: tea.KeyDown}
	space := tea.KeyPressMsg{Code: tea.KeySpace, Text: " "}
	ctrl := func(r rune) tea.Msg { return tea.KeyPressMsg{Code: r, Mod: tea.ModCtrl} }
	typed := func(text string) []tea.Msg {
		var keys []tea.Msg
		for _, r := range text {
			keys = append(keys, tea.KeyPressMsg{Code: r, Text: string(r)})
		}
		return keys
	}
	keys := func(groups ...[]tea.Msg) []tea.Msg {
		var all []tea.Msg
		for _, g := range groups {
			all = append(all, g...)
		}
		return all
	}
	registerShots("discord",
		shotState{"list", discordShot(nil)},
		shotState{"cursor-failed", discordShot(nil, down)},
		shotState{"filtering", discordShot(nil, typed("garden")...)},
		shotState{"no-match", discordShot(nil, typed("zzz")...)},
		shotState{"confirm-delete", discordShot(nil, ctrl('d'))},
		shotState{"copied-invite", discordShot(nil, ctrl('l'))},
		shotState{"loading", func(w, h int) string {
			m := NewDiscordPageModel(nil, "v")
			m.SetSize(w, h)
			return m.View()
		}},
		shotState{"empty", func(w, h int) string {
			m := discordModel(w, h, nil)
			m, _ = m.Update(discordLoadedMsg{Gen: m.Generation, Mounted: true, Sessions: discordSessions})
			return m.View()
		}},
		shotState{"extension-off", func(w, h int) string {
			m := NewDiscordPageModel(nil, "v")
			m.SetSize(w, h)
			m, _ = m.Update(discordLoadedMsg{Gen: m.Generation})
			return m.View()
		}},
		shotState{"load-failed", func(w, h int) string {
			m := NewDiscordPageModel(nil, "v")
			m.SetSize(w, h)
			m, _ = m.Update(discordLoadedMsg{Gen: m.Generation, Err: errors.New("daemon connection unavailable")})
			return m.View()
		}},
		shotState{"form-add", discordShot(nil, ctrl('o'))},
		shotState{"form-add-session", discordShot(nil, ctrl('o'), tab)},
		shotState{"form-add-owner", discordShot(nil, keys([]tea.Msg{ctrl('o')}, typed("albedo"), []tea.Msg{tab, tab}, typed("MTEw.Gx.abc"), []tea.Msg{tab})...)},
		shotState{"form-invalid", discordShot(nil, ctrl('o'), ctrl('s'))},
		shotState{"form-edit", discordShot(nil, ctrl('e'))},
		shotState{"channels", discordOpenShot(nil)},
		shotState{"channels-cycled", discordOpenShot(nil, down, down, down, space)},
		shotState{"channels-filter", discordOpenShot(nil, typed("albe")...)},
		shotState{"channels-offline", func(w, h int) string {
			m := discordModel(w, h, nil)
			m, _ = m.Update(down)
			m, _ = m.Update(enter)
			m, _ = m.Update(discordLoadedMsg{Gen: m.Generation, Mounted: true, Sessions: discordSessions, Bots: galleryBots, DMs: &daemon.DiscordDMs{Owner: galleryDMs.Owner}, GuildsErr: errors.New("bot_offline")})
			return m.View()
		}},
		shotState{"dms", discordOpenShot(nil, tab)},
		shotState{"dms-request", discordOpenShot(nil, tab, down, down)},
		shotState{"dms-confirm-remove", discordOpenShot(nil, tab, down, ctrl('d'))},
		shotState{"dms-add", discordOpenShot(nil, tab, ctrl('o'))},
		shotState{"save-failed", func(w, h int) string {
			m := discordOpenModel(w, h)
			m, _ = m.Update(space)
			m, _ = m.Update(discordSavedMsg{Gen: m.Generation, Err: errors.New("daemon refused the change: bot not found")})
			return m.View()
		}},
	)
}

// discordModel is the screen loaded with the gallery's bots.
func discordModel(width, height int, setup func(*DiscordPageModel)) DiscordPageModel {
	m := NewDiscordPageModel(nil, "v")
	m.now = func() time.Time { return galleryNow }
	m.SetSize(width, height)
	m, _ = m.Update(discordLoadedMsg{Gen: m.Generation, Mounted: true, Sessions: discordSessions, Bots: galleryBots})
	if setup != nil {
		setup(&m)
	}
	return m
}

// discordOpenModel is the first bot opened on its channels.
func discordOpenModel(width, height int) DiscordPageModel {
	m := discordModel(width, height, nil)
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	dms := galleryDMs
	m, _ = m.Update(discordLoadedMsg{Gen: m.Generation, Mounted: true, Sessions: discordSessions, Bots: galleryBots, Guilds: galleryGuilds, DMs: &dms})
	return m
}

func discordShot(setup func(*DiscordPageModel), keys ...tea.Msg) func(width, height int) string {
	return func(width, height int) string {
		m := discordModel(width, height, setup)
		for _, key := range keys {
			m, _ = m.Update(key)
		}
		return m.View()
	}
}

func discordOpenShot(setup func(*DiscordPageModel), keys ...tea.Msg) func(width, height int) string {
	return func(width, height int) string {
		m := discordOpenModel(width, height)
		if setup != nil {
			setup(&m)
		}
		for _, key := range keys {
			m, _ = m.Update(key)
		}
		return m.View()
	}
}
