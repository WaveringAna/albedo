package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"fmt"
	"slices"
	"strings"
	"time"
)

// View draws the bot list beside the highlighted bot, or the open bot's
// channels or DMs beside the highlighted one. A form takes the list's place,
// and a question takes the footer.
func (m DiscordPageModel) View() string {
	title := brand("albedo") + " " + DefaultStyles.Muted.Render("/discord")
	lv, right := m.listView, DefaultStyles.Faint.Render("all sessions")
	if m.Account.Connected {
		right = DefaultStyles.Faint.Render("signed in as @" + m.Account.Username)
	}
	bot, open := m.bot(m.Open)
	if open {
		title += DefaultStyles.Muted.Render(" › " + bot.Name)
		lv, right = m.inner, m.tabs()
		lv.Empty = m.innerEmpty(bot)
	} else {
		lv.Empty = "No bots match."
	}
	frame := lv.frame(title, right, m.footer(max(1, m.Width)))
	switch {
	case m.Provision != nil:
		frame.filter, frame.pane = "", nil
		frame.list = func(width, _ int) []string { return m.provisionRows(width) }
	case m.Login != nil:
		frame.filter, frame.pane = "", nil
		frame.list = func(width, _ int) []string { return m.Login.view(width) }
	case m.Auto != nil:
		frame.filter, frame.pane = "", nil
		frame.list = func(width, height int) []string { return scrolled(m.Auto.view(width), 1+m.Auto.Focus, height) }
	case m.Form != nil:
		frame.filter, frame.pane = "", nil
		frame.list = func(width, height int) []string { return scrolled(m.Form.view(width), 1+m.Form.Focus, height) }
	case m.Person != nil:
		frame.filter, frame.pane = "", nil
		frame.list = func(width, height int) []string { return m.Person.view(width) }
	case !m.Loaded || !m.Mounted || (!open && len(m.Bots) == 0):
		frame.filter, frame.pane = "", nil
		frame.list = func(width, _ int) []string { return m.guide(width) }
	case open:
		list := frame.list
		frame.list = func(width, height int) []string {
			head := m.statusRows(bot, width)
			if height < len(head)+3 {
				return list(width, height)
			}
			return append(head, list(width, height-len(head))...)
		}
	}
	return frame.view(m.Width, m.Height)
}

// tabs is the open bot's two lists, the shown one bright.
func (m DiscordPageModel) tabs() string {
	channels := 0
	for _, g := range m.Guilds {
		for _, c := range g.Channels {
			if c.Delivery != "off" {
				channels++
			}
		}
	}
	names := []string{fmt.Sprintf("channels %d", channels), fmt.Sprintf("dms %d", 1+len(m.DMs.Allowed))}
	if n := len(m.DMs.Requests); n > 0 {
		names[1] += DefaultStyles.Warning.Render(fmt.Sprintf(" +%d", n))
	}
	for i := range names {
		if discordTab(i) == m.Tab {
			names[i] = DefaultStyles.Bold.Render(names[i])
		} else {
			names[i] = DefaultStyles.Faint.Render(names[i])
		}
	}
	return names[0] + DefaultStyles.Decor.Render(" │ ") + names[1]
}

// guide stands in for the list while there is nothing to list: loading,
// a failed load, the extension off, or no bots yet.
func (m DiscordPageModel) guide(width int) []string {
	text := func(lines ...string) []string {
		var out []string
		for _, line := range lines {
			for _, l := range svWrap(line, max(1, width-6), 4) {
				out = append(out, "  "+l)
			}
		}
		return out
	}
	faint := DefaultStyles.Faint.Render
	switch {
	case m.Loading && !m.Loaded:
		return []string{faint("  loading discord bots…")}
	case !m.Loaded:
		return []string{faint("  discord bots did not load · ctrl+r retries")}
	case m.Missing:
		return text(DefaultStyles.Bold.Render("This daemon has no discord extension."), faint("Update albedo, restart the daemon, and come back."))
	case !m.Mounted:
		return text(
			DefaultStyles.Bold.Render("Discord bots are off."),
			"",
			"Open /extensions, select discord and press enter to turn it on for every session.",
			faint("Bots connect as soon as it is on; come back here to add one."),
		)
	}
	step := func(n, title, detail string) []string {
		lines := []string{"  " + DefaultStyles.Prompt.Render(n) + "  " + title}
		for _, l := range svWrap(detail, max(1, width-9), 3) {
			lines = append(lines, "     "+faint(l))
		}
		return append(lines, "")
	}
	rows := []string{"  " + DefaultStyles.Bold.Render("Give a session its own Discord bot")}
	for _, l := range svWrap("It reads the channels you pick and DMs from people you allow, and replies as the session.", max(1, width-4), 2) {
		rows = append(rows, "  "+faint(l))
	}
	rows = append(rows, "")
	rows = append(rows, step("1", "Create the bot in Discord", "discord.com/developers/applications → New Application → Bot → Reset Token, and turn on Message Content Intent on the same page.")...)
	rows = append(rows, step("2", "Add it here with ctrl+o", "Paste the token and your Discord user ID (Settings → Advanced → Developer Mode, then right-click yourself → Copy User ID). You can always DM it. Or press ctrl+n in that form and albedo does steps 1 to 3 with your Discord login.")...)
	rows = append(rows, step("3", "Invite it with ctrl+l", "Copy the invite link, open it, pick a server; then press enter on the bot to choose the channels it reads.")...)
	return rows
}

// innerEmpty says why the open bot lists nothing.
func (m DiscordPageModel) innerEmpty(bot daemon.DiscordBot) string {
	switch {
	case m.Loading:
		return "loading…"
	case m.Tab == discordDMs:
		return "No one matches."
	case m.GuildsErr != "" && bot.State == "failed":
		return "Channels show once the bot connects; fix the problem above with ctrl+e."
	case m.GuildsErr != "" && bot.State == "disabled":
		return "The bot is off. Turn it on with ctrl+t in the bot list to see its channels."
	case m.GuildsErr != "" && bot.State != "online":
		return "Channels show once the bot is online; it is " + bot.State + "…"
	case m.GuildsErr != "":
		return "Channels did not load: " + m.GuildsErr
	case len(m.Guilds) == 0:
		return "The bot is in no server yet. Press ctrl+l to copy its invite link, open it and pick a server."
	}
	return "No channels match."
}

// statusRows head the open bot's lists: its state, and its invite link.
func (m DiscordPageModel) statusRows(bot daemon.DiscordBot, width int) []string {
	lead, state := botState(bot)
	invite := DefaultStyles.Faint.Render("invite  ") + bot.Invite + DefaultStyles.Faint.Render("  ctrl+l copies")
	if bot.Invite == "" {
		invite = DefaultStyles.Faint.Render("invite  appears once the bot has connected")
	}
	rows := []string{"  " + lead + " " + state}
	if bot.State == "failed" && bot.Detail != "" {
		for _, l := range svWrap(bot.Detail, max(1, width-6), 2) {
			rows = append(rows, "    "+DefaultStyles.Error.Render(l))
		}
	}
	rows = append(rows, "  "+invite, "")
	for i, row := range rows {
		rows[i] = svFit(row, width)
	}
	return rows
}

// botState is a bot's dot and what it is doing, in words.
func botState(bot daemon.DiscordBot) (string, string) {
	as := ""
	if bot.Username != "" {
		as = " as @" + bot.Username
	}
	switch bot.State {
	case "online":
		return DefaultStyles.Success.Render("●"), "online" + as
	case "connecting":
		return DefaultStyles.Busy.Render("◌"), "connecting…"
	case "reconnecting":
		return DefaultStyles.Warning.Render("◌"), "reconnecting" + cmp.Or(prefixed(" · ", bot.Detail), "…")
	case "failed":
		return DefaultStyles.Error.Render("●"), "failed"
	}
	return DefaultStyles.Faint.Render("○"), "off"
}

func prefixed(prefix, text string) string {
	if text == "" {
		return ""
	}
	return prefix + text
}

// footer is the keys for what is open and one status.
func (m DiscordPageModel) footer(width int) string {
	switch {
	case m.Provision != nil:
		status, urgent := m.status()
		return footerLine(width, m.provisionHints(), status, urgent)
	case m.Login != nil:
		return m.formFooter(width, footerLine(width, []hint{{"ctrl+s", "sign in"}, {"esc", "cancel"}}, "", false))
	case m.Auto != nil:
		return m.formFooter(width, m.Auto.footer(width))
	case m.Form != nil:
		return m.formFooter(width, m.Form.footer(width))
	case m.Person != nil:
		return m.formFooter(width, m.Person.footer(width))
	case m.confirm.asking():
		return m.confirm.footer(width, m.Error)
	}
	status, urgent := m.status()
	return footerLine(width, m.hints(), status, urgent)
}

// status is the footer's state beside the keys.
func (m DiscordPageModel) status() (string, bool) {
	switch {
	case m.Error != "":
		return DefaultStyles.Error.Render(m.Error), true
	case m.Saving:
		return DefaultStyles.Busy.Render(m.savingLabel()), true
	case m.Loading:
		return DefaultStyles.Faint.Render("loading…"), false
	case m.Notice != "":
		return DefaultStyles.Warning.Render(m.Notice), true
	case m.SessionOff && m.Mounted:
		return DefaultStyles.Warning.Render("discord is off for this session · /extensions"), false
	}
	return "", false
}

// hints are the keys of what is shown, the row's main action first.
func (m DiscordPageModel) hints() []hint {
	switch {
	case !m.Loaded || !m.Mounted:
		return []hint{{"ctrl+r", "retry"}, {"esc", "back"}}
	case m.Open != "" && m.Tab == discordDMs:
		row, selected := m.inner.highlighted()
		kind, _ := dmRowKind(row.key)
		var hints []hint
		switch {
		case selected && kind == "request":
			hints = append(hints, hint{"enter", "allow"}, hint{"ctrl+x", "dismiss"})
		case selected && kind == "allowed":
			hints = append(hints, hint{"ctrl+d", "remove"})
		}
		return append(hints, hint{"ctrl+o", "add person"}, hint{"tab", "channels"}, hint{"ctrl+l", "copy invite"}, hint{"ctrl+e", "edit bot"}, hint{"ctrl+r", "refresh"}, hint{"esc", "bots"})
	case m.Open != "":
		var hints []hint
		if _, selected := m.inner.highlighted(); selected {
			hints = append(hints, hint{"space", "delivery"}, hint{"ctrl+t", "mentions only"})
		}
		return append(hints, hint{"tab", "dms"}, hint{"ctrl+l", "copy invite"}, hint{"ctrl+e", "edit bot"}, hint{"ctrl+r", "refresh"}, hint{"esc", "bots"})
	}
	bot, selected := m.current()
	var hints []hint
	if selected {
		hints = append(hints, hint{"enter", "channels & dms"}, hint{"ctrl+l", "copy invite"})
	}
	hints = append(hints, hint{"ctrl+o", "add bot"})
	if selected {
		hints = append(hints, hint{"ctrl+t", "turn " + onOff(!bot.Enabled)}, hint{"ctrl+e", "edit"}, hint{"ctrl+d", "delete"})
	}
	if m.Account.Connected {
		hints = append(hints, hint{"ctrl+u", "forget discord login"})
	}
	return append(hints, hint{"ctrl+r", "refresh"}, hint{"esc", "back"})
}

// formFooter is a form's keys, with a failure or the save in flight above them.
// savingLabel says what a long save waits on. Connecting a login in browser
// mode waits for a person to sign in, which is not the same as saving.
func (m DiscordPageModel) savingLabel() string {
	if m.Login != nil && m.Login.browser {
		return "waiting for Discord — sign in in the Chrome window…"
	}
	return "saving…"
}

func (m DiscordPageModel) formFooter(width int, line string) string {
	switch {
	case m.Error != "":
		return footerLine(width, nil, DefaultStyles.Error.Render(m.Error), true) + "\n" + line
	case m.Saving:
		return footerLine(width, nil, DefaultStyles.Busy.Render(m.savingLabel()), true) + "\n" + line
	}
	return line
}

// botEntry is how a bot reads in the list: its dot, its name, its Discord
// user and reach, and refused DMs waiting at the edge.
func (m DiscordPageModel) botEntry(bot daemon.DiscordBot) listEntry {
	lead, _ := botState(bot)
	desc := plural(bot.Channels, "channel") + " · " + dmReach(bot.Allowed)
	if bot.Username != "" {
		desc = "@" + bot.Username + " · " + desc
	}
	tag := ""
	switch {
	case bot.Requests > 0:
		tag = DefaultStyles.Warning.Render(plural(bot.Requests, "DM request"))
	case bot.State == "failed":
		tag = DefaultStyles.Error.Render("failed")
	}
	section := sessionLabel(m.Sessions, bot.SessionID, m.SessionID)
	return listEntry{
		key: bot.ID, section: section, lead: lead, name: bot.Name, desc: desc, tag: tag,
		search: []string{section, bot.State},
		detail: func(width int) []string { return m.botDetails(bot, width) },
	}
}

// botDetails is the list's pane: what the bot is doing and why, where it
// lives, who may reach it, and how to invite it.
func (m DiscordPageModel) botDetails(bot daemon.DiscordBot, width int) []string {
	_, state := botState(bot)
	lines := paneTitle(bot.Name, state, width)
	if bot.State == "failed" || bot.State == "reconnecting" {
		for _, l := range svWrap(cmp.Or(bot.Detail, "no reason given"), width, 4) {
			lines = append(lines, DefaultStyles.Error.Render(l))
		}
		lines = append(lines, "")
	}
	lines = append(lines, factRows("session", sessionLabel(m.Sessions, bot.SessionID, m.SessionID), width)...)
	lines = append(lines, factRows("owner", bot.OwnerID+" · always allowed", width)...)
	lines = append(lines, factRows("reads", plural(bot.Channels, "channel"), width)...)
	dms := dmReach(bot.Allowed)
	if bot.Requests > 0 {
		dms += " · " + plural(bot.Requests, "request") + " waiting"
	}
	lines = append(lines, factRows("dms", dms, width)...)
	lines = append(lines, factRows("invite", cmp.Or(bot.Invite, "appears once the bot has connected"), width)...)
	lines = append(lines, "")
	return append(lines, paneNote("Enter chooses its channels and who may DM it.", width)...)
}

// channelEntries lay each server out as Discord does: channels without a
// category first, then each category's channels under it.
func (m DiscordPageModel) channelEntries() []listEntry {
	var rows []listEntry
	for _, g := range m.Guilds {
		channels := slices.Clone(g.Channels)
		slices.SortStableFunc(channels, func(a, b daemon.DiscordChannel) int { return cmp.Compare(a.Position, b.Position) })
		isCategory := func(id string) bool {
			return slices.ContainsFunc(channels, func(c daemon.DiscordChannel) bool { return c.ID == id && c.Type == channelCategory })
		}
		add := func(section, category string, c daemon.DiscordChannel) {
			rows = append(rows, m.channelEntry(g, section, category, c))
		}
		for _, c := range channels {
			if c.Type != channelCategory && !isCategory(c.ParentID) {
				add(g.Name, "", c)
			}
		}
		for _, cat := range channels {
			if cat.Type != channelCategory {
				continue
			}
			for _, c := range channels {
				if c.ParentID == cat.ID && c.Type != channelCategory {
					add(g.Name+" › "+cat.Name, cat.Name, c)
				}
			}
		}
	}
	return rows
}

const channelCategory = 4

func (m DiscordPageModel) channelEntry(g daemon.DiscordGuild, section, category string, c daemon.DiscordChannel) listEntry {
	desc := map[int]string{2: "voice chat", 5: "announcements", 15: "forum"}[c.Type]
	tag := ""
	if c.MentionsOnly && c.Delivery != "off" {
		tag = DefaultStyles.Muted.Render("@mentions only")
	}
	return listEntry{
		key: c.ID, section: section, lead: deliveryBadge(c.Delivery), name: "#" + c.Name, desc: desc, tag: tag,
		search: []string{section},
		detail: func(width int) []string { return channelDetails(g, category, c, width) },
	}
}

// deliveryBadge is a channel's delivery as the list shows it.
func deliveryBadge(delivery string) string {
	switch delivery {
	case "turn":
		return DefaultStyles.Success.Render("end of turn")
	case "tool":
		return DefaultStyles.Prompt.Render("after tool")
	}
	return DefaultStyles.Faint.Render("off")
}

// channelDetails explain what the channel's setting does.
func channelDetails(g daemon.DiscordGuild, category string, c daemon.DiscordChannel, width int) []string {
	what := map[string]string{
		"off":  "not read · the session never sees this channel",
		"turn": "read · messages wait while the session works, then start its next turn together",
		"tool": "read · messages reach a working session after its current tool call",
	}[c.Delivery]
	lines := paneTitle("#"+c.Name, what, width)
	lines = append(lines, factRows("server", g.Name, width)...)
	if category != "" {
		lines = append(lines, factRows("category", category, width)...)
	}
	mentions := "every message"
	if c.MentionsOnly {
		mentions = "only messages that @mention the bot"
	}
	lines = append(lines, factRows("reads", mentions, width)...)
	lines = append(lines, factRows("id", c.ID, width)...)
	lines = append(lines, "")
	return append(lines, paneNote("space cycles off → end of turn → after tool call. ctrl+t reads @mentions only. Threads follow their channel; other bots' messages count like anyone's.", width)...)
}

// dmEntries are you, the people you allowed, and the people asking.
func (m DiscordPageModel) dmEntries() []listEntry {
	owner := m.DMs.Owner
	rows := []listEntry{{
		key: "owner:" + owner.UserID, section: "you", name: cmp.Or(owner.Name, "you"), desc: owner.UserID,
		tag:    DefaultStyles.Faint.Render("always allowed"),
		detail: func(width int) []string { return m.personDetails("owner", owner.UserID, width) },
	}}
	now := m.now()
	for _, p := range m.DMs.Allowed {
		rows = append(rows, listEntry{
			key: "allowed:" + p.UserID, section: "allowed", name: cmp.Or(p.Name, p.UserID), desc: p.UserID,
			tag:    DefaultStyles.Faint.Render("added " + ago(now, p.AddedAt)),
			detail: func(width int) []string { return m.personDetails("allowed", p.UserID, width) },
		})
	}
	for _, r := range m.DMs.Requests {
		rows = append(rows, listEntry{
			key: "request:" + r.UserID, section: "wants to DM you", name: "@" + r.Username, desc: "“" + r.Preview + "”",
			tag:    DefaultStyles.Warning.Render(plural(r.Count, "message") + " · " + ago(now, r.LastAt)),
			search: []string{r.UserID},
			detail: func(width int) []string { return m.personDetails("request", r.UserID, width) },
		})
	}
	return rows
}

// personDetails is the DMs pane for one person.
func (m DiscordPageModel) personDetails(kind, user string, width int) []string {
	now := m.now()
	switch kind {
	case "owner":
		lines := paneTitle(cmp.Or(m.DMs.Owner.Name, "you"), "the bot's owner · always allowed", width)
		lines = append(lines, factRows("user id", user, width)...)
		return append(append(lines, ""), paneNote("Your DMs reach the session after its current tool call. Change your ID with ctrl+e.", width)...)
	case "allowed":
		i := slices.IndexFunc(m.DMs.Allowed, func(p daemon.DiscordPerson) bool { return p.UserID == user })
		if i < 0 {
			return nil
		}
		p := m.DMs.Allowed[i]
		lines := paneTitle(cmp.Or(p.Name, p.UserID), "allowed to DM the session", width)
		lines = append(lines, factRows("user id", p.UserID, width)...)
		lines = append(lines, factRows("added", ago(now, p.AddedAt), width)...)
		return append(append(lines, ""), paneNote("Their DMs reach the session after its current tool call. ctrl+d removes them.", width)...)
	}
	i := slices.IndexFunc(m.DMs.Requests, func(r daemon.DiscordRequest) bool { return r.UserID == user })
	if i < 0 {
		return nil
	}
	r := m.DMs.Requests[i]
	lines := paneTitle("@"+r.Username, "wants to DM you · not allowed yet", width)
	lines = append(lines, factRows("user id", r.UserID, width)...)
	lines = append(lines, factRows("sent", plural(r.Count, "message")+" · last "+ago(now, r.LastAt), width)...)
	lines = append(lines, "", DefaultStyles.Muted.Render("latest"))
	for _, l := range svWrap(r.Preview, width, 6) {
		lines = append(lines, "  "+l)
	}
	return append(append(lines, ""), paneNote("Refused DMs never reach the session. enter allows them from now on; ctrl+x dismisses.", width)...)
}

// dmReach says who may DM a bot besides its owner.
func dmReach(allowed int) string {
	if allowed == 0 {
		return "only you can DM"
	}
	return fmt.Sprintf("you + %d can DM", allowed)
}

// dmRowKind splits a DMs row key into its kind and user ID.
func dmRowKind(key string) (string, string) {
	kind, user, _ := strings.Cut(key, ":")
	return kind, user
}

// ago is how long before now a unix-millisecond time was.
func ago(now time.Time, ms int64) string {
	if ms <= 0 {
		return "a while ago"
	}
	return quotaSpan(now.Sub(time.UnixMilli(ms))) + " ago"
}

// plural counts n of a thing, with its plural form when it is not just +s.
func plural(n int, one string, many ...string) string {
	if n == 1 {
		return "1 " + one
	}
	if len(many) > 0 {
		return fmt.Sprintf("%d %s", n, many[0])
	}
	return fmt.Sprintf("%d %ss", n, one)
}
