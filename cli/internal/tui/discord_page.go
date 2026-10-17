package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"errors"
	"slices"
	"time"

	tea "charm.land/bubbletea/v2"
)

// DiscordPageModel is the Discord screen: every session's bot grouped by
// session with its live state, and for the open bot the channels it reads
// and the people who may DM it. Bots connect on their own time, so the
// screen polls while it is open.
type DiscordPageModel struct {
	Conn      *daemon.Connection
	SessionID string
	Sessions  []daemon.Session
	Bots      []daemon.DiscordBot
	Form      *discordForm
	Person    *discordPersonForm
	// Open is the bot whose channels or DMs are shown; empty for the list.
	Open string
	Tab  discordTab
	// Guilds are the open bot's servers, read from the running bot;
	// GuildsErr says why they could not be, usually that it is offline.
	Guilds    []daemon.DiscordGuild
	GuildsErr string
	DMs       daemon.DiscordDMs
	// inner is the open bot's channels or DMs, with its own filter.
	inner listView
	pageStatus
	listView
	confirm
	// Mounted reports the extension on globally; its API exists only then.
	Mounted bool
	// SessionOff reports the extension off for this session, whose agent
	// then cannot answer through its bot.
	SessionOff bool
	Loaded     bool
	// Missing reports a daemon without the extension at all.
	Missing bool
	// pollErr is the last failure a background refresh showed, so the next
	// good one can clear it.
	pollErr string
	// ticker tells this screen's poll ticks from an earlier one's.
	ticker int
	now    func() time.Time

	// selected is the bot to put the cursor on once it is listed.
	selected string
}

type discordTab int

const (
	discordChannels discordTab = iota
	discordDMs
)

type discordLoadedMsg struct {
	Err        error
	Sessions   []daemon.Session
	Bots       []daemon.DiscordBot
	Guilds     []daemon.DiscordGuild
	GuildsErr  error
	DMs        *daemon.DiscordDMs
	Gen        int
	Quiet      bool
	Mounted    bool
	SessionOff bool
	Missing    bool
}

type discordSavedMsg struct {
	Err    error
	Notice string
	Gen    int
	Reload bool
}

type discordTickMsg struct{ ticker int }

type DiscordPageDoneMsg struct{}
type ChatOpenDiscordPageMsg struct{}

// discordPoll is how often an open screen refreshes bot state.
const discordPoll = 3 * time.Second

func NewDiscordPageModel(conn *daemon.Connection, sessionID string) DiscordPageModel {
	return DiscordPageModel{
		Conn:       conn,
		SessionID:  sessionID,
		Mounted:    true,
		pageStatus: newPageStatus(true),
		listView:   newListView("Search bots"),
		inner:      newListView("Search channels"),
		ticker:     nextPageGeneration(),
		now:        time.Now,
	}
}

func (m *DiscordPageModel) SetSize(width, height int) {
	m.pageStatus.SetSize(width, height)
	m.listView.setSize(width, height)
	m.inner.setSize(width, height)
}

// Confirming reports a question waiting for enter or esc.
func (m DiscordPageModel) Confirming() bool { return m.confirm.asking() }

func (m DiscordPageModel) Init() tea.Cmd {
	return tea.Batch(m.loadCmd(m.Generation, false), m.tick())
}

func (m DiscordPageModel) tick() tea.Cmd {
	ticker := m.ticker
	return tea.Tick(discordPoll, func(time.Time) tea.Msg { return discordTickMsg{ticker} })
}

// loadCmd reads the bots, and the open bot's DMs and channels. A quiet
// load is a background refresh: it keeps the sessions it has and reads the
// channels again only while they are missing.
func (m DiscordPageModel) loadCmd(gen int, quiet bool) tea.Cmd {
	conn, session, open := m.Conn, m.SessionID, m.Open
	wantGuilds := open != "" && (!quiet || m.Guilds == nil)
	return func() tea.Msg {
		msg := discordLoadedMsg{Gen: gen, Quiet: quiet, Mounted: true}
		if conn == nil {
			msg.Err = errors.New("daemon connection unavailable")
			return msg
		}
		ctx := context.Background()
		extensions, err := daemon.ListExtensions(ctx, conn, session)
		if err != nil {
			msg.Err = err
			return msg
		}
		i := slices.IndexFunc(extensions, func(ext ExtensionItem) bool { return ext.Name == "discord" })
		if i < 0 {
			msg.Missing, msg.Mounted = true, false
			return msg
		}
		msg.Mounted, msg.SessionOff = extensions[i].GlobalEnabled, !extensions[i].Enabled
		if !msg.Mounted {
			return msg
		}
		if !quiet {
			all, err := daemon.ListAllSessions(ctx, conn)
			if err != nil {
				msg.Err = err
				return msg
			}
			for _, s := range all {
				if s.ID == session {
					msg.Sessions = slices.Insert(msg.Sessions, 0, s)
				} else {
					msg.Sessions = append(msg.Sessions, s)
				}
			}
		}
		if msg.Bots, msg.Err = daemon.ListDiscordBots(ctx, conn); msg.Err != nil || open == "" {
			return msg
		}
		dms, err := daemon.GetDiscordDMs(ctx, conn, open)
		if err != nil {
			msg.Err = err
			return msg
		}
		msg.DMs = &dms
		if wantGuilds {
			msg.Guilds, msg.GuildsErr = daemon.ListDiscordGuilds(ctx, conn, open)
		}
		return msg
	}
}

// reload starts a load the user asked for, which waits for keys.
func (m DiscordPageModel) reload() (DiscordPageModel, tea.Cmd) {
	m.Error, m.Notice, m.pollErr = "", "", ""
	m.Loading, m.Generation = true, nextPageGeneration()
	return m, m.loadCmd(m.Generation, false)
}

// begin runs one change and reports it with notice; reload reads everything
// again afterwards.
func (m DiscordPageModel) begin(notice string, reload bool, change func(context.Context, *daemon.Connection) error) (DiscordPageModel, tea.Cmd) {
	m.Error, m.Notice, m.pollErr = "", "", ""
	m.Saving = true
	m.Generation = nextPageGeneration()
	conn, gen := m.Conn, m.Generation
	return m, func() tea.Msg {
		if conn == nil {
			return discordSavedMsg{Gen: gen, Err: errors.New("daemon connection unavailable")}
		}
		return discordSavedMsg{Gen: gen, Notice: notice, Reload: reload, Err: change(context.Background(), conn)}
	}
}

func (m DiscordPageModel) Update(msg tea.Msg) (DiscordPageModel, tea.Cmd) {
	switch msg := msg.(type) {
	case discordLoadedMsg:
		return m.loaded(msg), nil
	case discordSavedMsg:
		if msg.Gen != m.Generation {
			return m, nil
		}
		m.Saving = false
		if msg.Err != nil {
			m.Error = msg.Err.Error()
			if _, uncertain := errors.AsType[*daemon.UncertainOutcomeError](msg.Err); uncertain {
				return m, nil
			}
			// What was shown ahead of the daemon may be wrong now.
			m.Loading, m.Generation = true, nextPageGeneration()
			return m, m.loadCmd(m.Generation, false)
		}
		m.Form, m.Person, m.Notice = nil, nil, msg.Notice
		if !msg.Reload {
			return m, nil
		}
		m.Loading, m.Generation = true, nextPageGeneration()
		return m, m.loadCmd(m.Generation, false)
	case discordTickMsg:
		if msg.ticker != m.ticker {
			return m, nil
		}
		if m.Loading || m.Saving || !m.Loaded || !m.Mounted {
			return m, m.tick()
		}
		return m, tea.Batch(m.tick(), m.loadCmd(m.Generation, true))
	case tea.KeyPressMsg:
		return m.handleKey(msg)
	case tea.PasteMsg:
		var cmd tea.Cmd
		switch {
		case m.Saving:
		case m.Form != nil:
			_, cmd = m.Form.update(msg)
		case m.Person != nil:
			_, cmd = m.Person.update(msg)
		}
		return m, cmd
	}
	return m, nil
}

// loaded takes a load's reply. A background refresh that fails shows its
// failure until one succeeds; one that succeeds never moves the cursor.
func (m DiscordPageModel) loaded(msg discordLoadedMsg) DiscordPageModel {
	if msg.Gen != m.Generation {
		return m
	}
	if msg.Quiet {
		if msg.Err != nil {
			m.Error, m.pollErr = msg.Err.Error(), msg.Err.Error()
			return m
		}
		if m.Error != "" && m.Error == m.pollErr {
			m.Error = ""
		}
		m.pollErr = ""
	} else if !m.settle(msg.Gen, msg.Err, &m.Loading) {
		return m
	}
	m.Loaded = true
	m.Mounted, m.SessionOff, m.Missing = msg.Mounted, msg.SessionOff, msg.Missing
	if msg.Sessions != nil {
		m.Sessions = msg.Sessions
	}
	m.setBots(msg.Bots)
	if m.selected != "" && slices.ContainsFunc(m.Bots, func(b daemon.DiscordBot) bool { return b.ID == m.selected }) {
		m.selectRow(m.selected)
		m.selected = ""
	}
	if m.Open == "" {
		return m
	}
	if _, ok := m.bot(m.Open); !ok {
		// Deleted elsewhere: back to the list.
		m.Open, m.Guilds, m.GuildsErr = "", nil, ""
		return m
	}
	if msg.DMs != nil {
		m.DMs = *msg.DMs
	}
	switch {
	case msg.GuildsErr != nil:
		m.Guilds, m.GuildsErr = nil, msg.GuildsErr.Error()
	case msg.Guilds != nil:
		m.Guilds, m.GuildsErr = msg.Guilds, ""
	}
	m.setInner()
	return m
}

// setBots lists the bots under the sessions they speak for, current first,
// keeping the cursor on its bot.
func (m *DiscordPageModel) setBots(bots []daemon.DiscordBot) {
	rank := func(id string) int {
		if i := slices.IndexFunc(m.Sessions, func(s daemon.Session) bool { return s.ID == id }); i >= 0 {
			return i
		}
		return len(m.Sessions)
	}
	bots = slices.Clone(bots)
	slices.SortStableFunc(bots, func(a, b daemon.DiscordBot) int { return cmp.Compare(rank(a.SessionID), rank(b.SessionID)) })
	m.Bots = bots
	rows := make([]listEntry, len(bots))
	for i, bot := range bots {
		rows[i] = m.botEntry(bot)
	}
	m.setRows(rows)
}

// setInner lists the open bot's channels or DMs, keeping the cursor.
func (m *DiscordPageModel) setInner() {
	if m.Tab == discordDMs {
		m.inner.setRows(m.dmEntries())
	} else {
		m.inner.setRows(m.channelEntries())
	}
}

func (m DiscordPageModel) bot(id string) (daemon.DiscordBot, bool) {
	i := slices.IndexFunc(m.Bots, func(b daemon.DiscordBot) bool { return b.ID == id })
	if i < 0 {
		return daemon.DiscordBot{}, false
	}
	return m.Bots[i], true
}

// current is the bot under the cursor, or the open one.
func (m DiscordPageModel) current() (daemon.DiscordBot, bool) {
	if m.Open != "" {
		return m.bot(m.Open)
	}
	row, ok := m.highlighted()
	if !ok {
		return daemon.DiscordBot{}, false
	}
	return m.bot(row.key)
}

// freeSessions are the sessions without a bot, in order, for a new one.
func (m DiscordPageModel) freeSessions() sessionChoice {
	var free []daemon.Session
	for _, s := range m.Sessions {
		if !slices.ContainsFunc(m.Bots, func(b daemon.DiscordBot) bool { return b.SessionID == s.ID }) {
			free = append(free, s)
		}
	}
	choice := sessionChoice{Sessions: free, Current: m.SessionID}
	if len(free) > 0 {
		choice.Chosen = free[0].ID
	}
	return choice
}

// handleKey routes a key to the open part of the screen: a form, the
// question, the open bot, or the list.
func (m DiscordPageModel) handleKey(msg tea.KeyPressMsg) (DiscordPageModel, tea.Cmd) {
	key := msg.String()
	switch {
	case m.Form != nil:
		return m.formKey(msg)
	case m.Person != nil:
		return m.personKey(msg)
	case m.confirm.asking():
		return m.confirmKey(msg)
	case (key == "esc" || key == "ctrl+c") && m.Open != "":
		m.Open, m.Guilds, m.GuildsErr, m.Error, m.Notice = "", nil, "", "", ""
		m.Generation = nextPageGeneration() // a detail load in flight is stale now
		m.Loading = false
		return m, nil
	case key == "esc" || key == "ctrl+c":
		return m, func() tea.Msg { return DiscordPageDoneMsg{} }
	case m.Saving || m.Loading:
		return m, nil
	case key == "ctrl+r":
		return m.reload()
	case !m.Loaded || !m.Mounted:
		return m, nil
	case m.Open != "":
		return m.detailKey(msg)
	}
	return m.browseKey(msg)
}

func (m DiscordPageModel) formKey(msg tea.KeyPressMsg) (DiscordPageModel, tea.Cmd) {
	if msg.String() == "esc" {
		m.Form, m.Error = nil, ""
		return m, nil
	}
	if m.Saving {
		return m, nil
	}
	submit, cmd := m.Form.update(msg)
	if !submit {
		return m, cmd
	}
	if m.Form.Editing == nil {
		request, err := m.Form.create()
		if err != nil {
			m.Error = err.Error()
			return m, nil
		}
		note := "Added " + request.Name + ". Copy its invite link with ctrl+l, then choose its channels."
		return m.begin(note, true, func(ctx context.Context, conn *daemon.Connection) error {
			_, err := daemon.CreateDiscordBot(ctx, conn, request)
			return err
		})
	}
	patch, err := m.Form.patch()
	switch {
	case err != nil:
		m.Error = err.Error()
		return m, nil
	case patch == nil:
		m.Form = nil
		m.Error, m.Notice = "", "No changes made."
		return m, nil
	}
	id, name := m.Form.Editing.ID, m.Form.value(discordFieldName)
	return m.begin("Saved "+name+".", true, func(ctx context.Context, conn *daemon.Connection) error {
		_, err := daemon.EditDiscordBot(ctx, conn, id, *patch)
		return err
	})
}

func (m DiscordPageModel) personKey(msg tea.KeyPressMsg) (DiscordPageModel, tea.Cmd) {
	if msg.String() == "esc" {
		m.Person, m.Error = nil, ""
		return m, nil
	}
	if m.Saving {
		return m, nil
	}
	submit, cmd := m.Person.update(msg)
	if !submit {
		return m, cmd
	}
	user, name, err := m.Person.person()
	if err != nil {
		m.Error = err.Error()
		return m, nil
	}
	bot := m.Open
	return m.begin("They can DM the bot now.", true, func(ctx context.Context, conn *daemon.Connection) error {
		_, err := daemon.AllowDiscordDM(ctx, conn, bot, user, name)
		return err
	})
}

// confirmKey runs the change a question asked about on enter; esc cancels and
// every other key is ignored.
func (m DiscordPageModel) confirmKey(msg tea.KeyPressMsg) (DiscordPageModel, tea.Cmd) {
	if !m.confirm.key(msg) {
		return m, nil
	}
	what, target := m.confirm.what, m.confirm.target
	m.confirm.dismiss()
	switch what {
	case "delete":
		bot, ok := m.bot(target)
		if !ok {
			return m, nil
		}
		m.Open = ""
		return m.begin("Deleted "+bot.Name+".", true, func(ctx context.Context, conn *daemon.Connection) error {
			return daemon.DeleteDiscordBot(ctx, conn, bot.ID, bot.Revision)
		})
	case "remove":
		bot := m.Open
		return m.begin("Removed. Their DMs will show up as requests again.", true, func(ctx context.Context, conn *daemon.Connection) error {
			return daemon.RemoveDiscordDM(ctx, conn, bot, target)
		})
	}
	return m, nil
}

func (m DiscordPageModel) browseKey(msg tea.KeyPressMsg) (DiscordPageModel, tea.Cmd) {
	bot, selected := m.current()
	switch msg.String() {
	case "enter":
		if selected {
			return m.openBot(bot)
		}
	case "ctrl+o":
		choice := m.freeSessions()
		if len(choice.Sessions) == 0 {
			m.Error = "Every session already has a bot; delete one or start a new session."
			return m, nil
		}
		m.Error, m.Notice = "", ""
		m.Form = newDiscordForm(nil, choice)
	case "ctrl+e":
		if selected {
			m.Error, m.Notice = "", ""
			m.Form = newDiscordForm(&bot, sessionChoice{Sessions: m.Sessions, Current: m.SessionID})
		}
	case "ctrl+d":
		if selected {
			m.Error = ""
			m.confirm.ask("delete", bot.ID, "delete", "The bot goes offline and forgets its channels and DM list; the Discord application stays. Delete "+bot.Name+"?")
		}
	case "ctrl+t":
		if selected {
			return m.toggleBot(bot)
		}
	case "ctrl+l":
		if selected {
			return m.copyInvite(bot)
		}
	default:
		cmd := m.listView.update(msg)
		return m, cmd
	}
	return m, nil
}

// openBot shows a bot's channels, starting a load of them and its DMs.
func (m DiscordPageModel) openBot(bot daemon.DiscordBot) (DiscordPageModel, tea.Cmd) {
	m.Open, m.Tab = bot.ID, discordChannels
	m.Guilds, m.GuildsErr, m.DMs = nil, "", daemon.DiscordDMs{}
	m.inner = newListView("Search channels")
	m.inner.setSize(m.Width, m.Height)
	return m.reload()
}

// toggleBot turns a bot on or off now; off disconnects it from Discord.
func (m DiscordPageModel) toggleBot(bot daemon.DiscordBot) (DiscordPageModel, tea.Cmd) {
	enabled := !bot.Enabled
	note := bot.Name + " is off; it left Discord and its messages stop."
	if enabled {
		note = bot.Name + " is on; it is connecting to Discord."
	}
	patch := daemon.DiscordBotPatch{Revision: bot.Revision, Enabled: &enabled}
	return m.begin(note, true, func(ctx context.Context, conn *daemon.Connection) error {
		_, err := daemon.EditDiscordBot(ctx, conn, bot.ID, patch)
		return err
	})
}

func (m DiscordPageModel) copyInvite(bot daemon.DiscordBot) (DiscordPageModel, tea.Cmd) {
	if bot.Invite == "" {
		m.Error, m.Notice = "No invite link yet: it appears once the bot has connected with a valid token.", ""
		return m, nil
	}
	m.Error, m.Notice = "", "Invite link copied. Open it in a browser and pick a server."
	return m, CopyText(bot.Invite)
}

func (m DiscordPageModel) detailKey(msg tea.KeyPressMsg) (DiscordPageModel, tea.Cmd) {
	bot, _ := m.current()
	switch msg.String() {
	case "tab", "shift+tab":
		m.Tab = 1 - m.Tab
		m.inner = newListView(map[discordTab]string{discordChannels: "Search channels", discordDMs: "Search people"}[m.Tab])
		m.inner.setSize(m.Width, m.Height)
		m.setInner()
		return m, nil
	case "ctrl+l":
		return m.copyInvite(bot)
	case "ctrl+e":
		m.Error, m.Notice = "", ""
		m.Form = newDiscordForm(&bot, sessionChoice{Sessions: m.Sessions, Current: m.SessionID})
		return m, nil
	}
	if m.Tab == discordDMs {
		return m.dmKey(msg)
	}
	return m.channelKey(msg)
}

// channelKey changes the highlighted channel at once and in place; the
// daemon's answer is trusted unless it refuses, which reloads.
func (m DiscordPageModel) channelKey(msg tea.KeyPressMsg) (DiscordPageModel, tea.Cmd) {
	row, ok := m.inner.highlighted()
	key := msg.String()
	if !ok || (key != "space" && key != "enter" && key != "ctrl+t") {
		cmd := m.inner.update(msg)
		return m, cmd
	}
	guild, channel, found := m.channel(row.key)
	if !found {
		return m, nil
	}
	if key == "ctrl+t" {
		channel.MentionsOnly = !channel.MentionsOnly
		if channel.Delivery == "off" {
			channel.Delivery = "turn"
		}
	} else {
		channel.Delivery = nextDelivery(channel.Delivery)
	}
	m.setChannel(channel)
	change := daemon.DiscordChannelChange{GuildID: guild.ID, GuildName: guild.Name, ChannelID: channel.ID, ChannelName: channel.Name, Delivery: channel.Delivery, MentionsOnly: channel.MentionsOnly}
	bot := m.Open
	return m.begin("", false, func(ctx context.Context, conn *daemon.Connection) error {
		_, err := daemon.SetDiscordChannel(ctx, conn, bot, change)
		return err
	})
}

func (m DiscordPageModel) dmKey(msg tea.KeyPressMsg) (DiscordPageModel, tea.Cmd) {
	row, selected := m.inner.highlighted()
	kind, user := dmRowKind(row.key)
	bot := m.Open
	switch msg.String() {
	case "ctrl+o":
		m.Error, m.Notice = "", ""
		m.Person = newDiscordPersonForm()
		return m, nil
	case "enter":
		if selected && kind == "request" {
			return m.begin("Allowed. Their next DM reaches the session.", true, func(ctx context.Context, conn *daemon.Connection) error {
				_, err := daemon.AllowDiscordDM(ctx, conn, bot, user, "")
				return err
			})
		}
		return m, nil
	case "ctrl+x":
		if selected && kind == "request" {
			return m.begin("Dismissed. If they DM again, they show up here again.", true, func(ctx context.Context, conn *daemon.Connection) error {
				return daemon.DismissDiscordRequest(ctx, conn, bot, user)
			})
		}
		return m, nil
	case "ctrl+d":
		if selected && kind == "allowed" {
			m.Error = ""
			m.confirm.ask("remove", user, "remove", "They will no longer reach the session by DM. Remove "+row.name+"?")
		}
		return m, nil
	}
	cmd := m.inner.update(msg)
	return m, cmd
}

// channel finds a listed channel and its server.
func (m DiscordPageModel) channel(id string) (daemon.DiscordGuild, daemon.DiscordChannel, bool) {
	for _, g := range m.Guilds {
		if i := slices.IndexFunc(g.Channels, func(c daemon.DiscordChannel) bool { return c.ID == id }); i >= 0 {
			return g, g.Channels[i], true
		}
	}
	return daemon.DiscordGuild{}, daemon.DiscordChannel{}, false
}

// setChannel shows a channel's new setting ahead of the daemon's answer.
func (m *DiscordPageModel) setChannel(channel daemon.DiscordChannel) {
	m.Guilds = slices.Clone(m.Guilds)
	for gi, g := range m.Guilds {
		if i := slices.IndexFunc(g.Channels, func(c daemon.DiscordChannel) bool { return c.ID == channel.ID }); i >= 0 {
			m.Guilds[gi].Channels = slices.Clone(g.Channels)
			m.Guilds[gi].Channels[i] = channel
		}
	}
	m.setInner()
}

// nextDelivery cycles off → end of turn → after tool call → off.
func nextDelivery(delivery string) string {
	switch delivery {
	case "off":
		return "turn"
	case "turn":
		return "tool"
	}
	return "off"
}

// selectRow puts the list's cursor on a bot, clearing a filter that hides it.
func (m *DiscordPageModel) selectRow(id string) {
	m.selected = id
	if i := slices.IndexFunc(m.shown, func(s listShown) bool { return m.rows[s.row].key == id }); i >= 0 {
		m.Cursor = i
		return
	}
	m.input.SetValue("")
	m.refilter(id)
}
