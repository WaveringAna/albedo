package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// Creating a bot automatically signs in to Discord as the user, makes the
// application, its bot, the Message Content intent and a token, and can add
// the bot to a server. This file is that flow: the login step when no login
// is stored, the form, and the progress view that answers two-factor
// prompts and falls back to the developer portal on a captcha.

// discordLoginForm asks once for the user's own Discord login: a pasted token,
// or a Chrome window a human signs in to (ctrl+b).
type discordLoginForm struct {
	form
	// browser takes the login from Discord's own web page in a window albedo
	// opens, instead of a pasted token.
	browser bool
}

func newDiscordLoginForm() *discordLoginForm {
	f := &discordLoginForm{form: newForm([]string{discordFieldLogin}, discordFieldLogin)}
	f.Inputs[discordFieldLogin].Placeholder = "paste your Discord user token"
	f.focus(discordFieldLogin)
	return f
}

func (f *discordLoginForm) update(msg tea.Msg) (submit bool, cmd tea.Cmd) {
	if submit, handled := f.key(msg, []string{discordFieldLogin}, 0); handled {
		return submit, nil
	}
	input := f.Inputs[discordFieldLogin]
	next, cmd := input.Update(msg)
	*input = next
	return false, cmd
}

func (f *discordLoginForm) view(width int) []string {
	f.fit(width - 17)
	rows := []string{DefaultStyles.Bold.Render("sign in to Discord to create bots"), ""}
	wrap := func(style func(...string) string, text string) {
		for _, l := range svWrap(text, max(1, width-4), 4) {
			rows = append(rows, "  "+style(l))
		}
	}
	wrap(DefaultStyles.Warning.Render, "This lets albedo act as your Discord account to create applications and add bots to servers. Automating a user account is against Discord's terms and can get the account limited; use it only if you accept that.")
	rows = append(rows, "")
	if f.browser {
		rows = append(rows, formRow(true, discordFieldLabels[discordFieldLogin], 14, "a Chrome window", width))
	} else {
		rows = append(rows, formRow(true, discordFieldLabels[discordFieldLogin], 14, f.Inputs[discordFieldLogin].View(), width))
	}
	rows = append(rows, "")
	if f.browser {
		wrap(DefaultStyles.Faint.Render, "albedo opens Chrome on Discord's own web app and waits while you sign in there. The window keeps that session, no token is stored anywhere, and ctrl+b goes back to pasting one.")
	} else {
		wrap(DefaultStyles.Faint.Render, "In Discord in a browser: DevTools → Network → any request to discord.com/api → copy the Authorization header. The daemon keeps it; kernels and bots never see it, and ctrl+u on the bot list forgets it.")
		wrap(DefaultStyles.Faint.Render, "Or press ctrl+b and sign in to a Chrome window instead, which needs no token at all.")
	}
	return rows
}

// discordAutoForm is the add form when albedo creates the bot: its name, the
// session it speaks for, and the server to add it to, or none.
type discordAutoForm struct {
	form
	sessionChoice
	// Servers are where the login may add bots; nil until they load.
	Servers   []daemon.DiscordAccountGuild
	ServerErr string
	// Server is the chosen server's id; empty is "invite it myself".
	Server string
}

var autoFields = []string{discordFieldName, discordFieldSession, discordFieldServer}

func newDiscordAutoForm(choice sessionChoice, name string) *discordAutoForm {
	f := &discordAutoForm{form: newForm(autoFields), sessionChoice: choice}
	f.Inputs[discordFieldName].Placeholder = "albedo"
	f.Inputs[discordFieldName].SetValue(name)
	f.Inputs[discordFieldSession].Placeholder = "type to filter"
	f.Inputs[discordFieldServer].Placeholder = "type to filter"
	f.focus(discordFieldName)
	return f
}

func (f *discordAutoForm) current() string { return autoFields[f.Focus] }

// serverOptions are the servers the filter leaves, after "none".
func (f *discordAutoForm) serverOptions() []daemon.DiscordAccountGuild {
	query := strings.ToLower(strings.TrimSpace(f.Inputs[discordFieldServer].Value()))
	options := []daemon.DiscordAccountGuild{{Name: noServer}}
	for _, g := range f.Servers {
		if query == "" || strings.Contains(strings.ToLower(g.Name), query) {
			options = append(options, g)
		}
	}
	return options
}

func (f *discordAutoForm) serverLabel() string {
	if i := slices.IndexFunc(f.Servers, func(g daemon.DiscordAccountGuild) bool { return g.ID == f.Server }); i >= 0 {
		return f.Servers[i].Name
	}
	return noServer
}

func (f *discordAutoForm) update(msg tea.Msg) (submit bool, cmd tea.Cmd) {
	if submit, handled := f.key(msg, autoFields, 0); handled {
		return submit, nil
	}
	key, _ := msg.(tea.KeyPressMsg)
	switch f.current() {
	case discordFieldSession:
		if f.step(f.Inputs[discordFieldSession].Value(), key.String()) {
			return false, nil
		}
	case discordFieldServer:
		if k := key.String(); k == "left" || k == "right" {
			options := f.serverOptions()
			i := slices.IndexFunc(options, func(g daemon.DiscordAccountGuild) bool { return g.ID == f.Server })
			by := map[string]int{"left": -1, "right": 1}[k]
			f.Server = options[(max(0, i)+by+len(options))%len(options)].ID
			return false, nil
		}
	}
	input := f.Inputs[f.current()]
	next, cmd := input.Update(msg)
	*input = next
	switch f.current() {
	case discordFieldSession:
		f.follow(input.Value())
	case discordFieldServer:
		if options := f.serverOptions(); !slices.ContainsFunc(options, func(g daemon.DiscordAccountGuild) bool { return g.ID == f.Server }) || (f.Server == "" && len(options) > 1 && input.Value() != "") {
			// Typing picks the first server that matches.
			f.Server = options[min(1, len(options)-1)].ID
		}
	}
	return false, cmd
}

func (f *discordAutoForm) request() (name string, err error) {
	name = f.value(discordFieldName)
	switch {
	case !validDiscordName(name):
		return "", errors.New("name: 1–64 characters")
	case strings.Contains(strings.ToLower(name), "discord"):
		return "", errors.New(`name: Discord refuses names that contain "discord"`)
	case f.Chosen == "":
		return "", errors.New("choose the session this bot speaks for")
	}
	return name, nil
}

func (f *discordAutoForm) view(width int) []string {
	f.fit(width - 17)
	indent := strings.Repeat(" ", 16)
	rows := []string{DefaultStyles.Bold.Render("create a discord bot automatically")}
	for i, key := range autoFields {
		value := f.Inputs[key].View()
		switch {
		case key == discordFieldSession && i != f.Focus:
			value = f.label()
		case key == discordFieldServer && i != f.Focus:
			value = f.serverLabel()
		}
		rows = append(rows, formRow(i == f.Focus, discordFieldLabels[key], 14, value, width))
		if i != f.Focus {
			continue
		}
		switch key {
		case discordFieldSession:
			rows = append(rows, f.rows(f.Inputs[discordFieldSession].Value(), indent, width)...)
		case discordFieldServer:
			rows = append(rows, f.serverRows(indent, width)...)
		}
		for _, line := range svWrap(f.help(), max(1, width-len(indent)), 3) {
			rows = append(rows, indent+DefaultStyles.Faint.Render(line))
		}
	}
	return rows
}

// serverRows list the matching servers around the chosen one.
func (f *discordAutoForm) serverRows(indent string, width int) []string {
	switch {
	case f.ServerErr != "":
		return []string{indent + DefaultStyles.Error.Render(ansi.Truncate("servers did not load: "+f.ServerErr, width-len(indent), "…"))}
	case f.Servers == nil:
		return []string{indent + DefaultStyles.Faint.Render("loading your servers…")}
	}
	options := f.serverOptions()
	chosen := max(0, slices.IndexFunc(options, func(g daemon.DiscordAccountGuild) bool { return g.ID == f.Server }))
	start := max(0, min(chosen-sessionChoices/2, len(options)-sessionChoices))
	w := width - len(indent)
	var rows []string
	for i := start; i < min(len(options), start+sessionChoices); i++ {
		if i == chosen {
			rows = append(rows, indent+selectedLine(ansi.Truncate(selectBar()+" "+options[i].Name, w, "…"), w))
		} else {
			rows = append(rows, indent+DefaultStyles.Faint.Render(ansi.Truncate("  "+options[i].Name, w, "…")))
		}
	}
	if more := len(options) - sessionChoices; more > 0 {
		rows = append(rows, indent+DefaultStyles.Faint.Render(fmt.Sprintf("  %d more · type to filter", more)))
	}
	return rows
}

func (f *discordAutoForm) help() string {
	switch f.current() {
	case discordFieldName:
		return "the application and bot name on Discord, and what you call it here"
	case discordFieldSession:
		return "the session that reads its channels and DMs and replies through it; one bot per session"
	}
	return "servers where you can manage the server; the bot is added with the permissions it needs"
}

func (f *discordAutoForm) footer(width int) string {
	var own []hint
	if c := f.current(); c != discordFieldName {
		own = []hint{{"←→", "choose"}}
	}
	keys := append(own, hint{"ctrl+s", "create"}, hint{"ctrl+n", "paste a token instead"}, hint{"tab/↑↓", "move"}, hint{"esc", "cancel"})
	return footerLine(width, keys, "", false)
}

// noServer is the server choice that leaves inviting to you.
const noServer = "none · I'll invite it myself"

type discordAccountMsg struct {
	Err     error
	Account daemon.DiscordAccount
	Gen     int
	// Then opens the automatic form once connected.
	Then bool
}

type discordServersMsg struct {
	Err     error
	Servers []daemon.DiscordAccountGuild
}

type discordProvisionMsg struct {
	Err       error
	Provision daemon.DiscordProvision
	Gen       int
}

type discordProvisionTickMsg struct{ ticker int }

// provisionPoll is how often a provision in progress is read again.
const provisionPoll = 500 * time.Millisecond

// spinnerFrames turn while a provision step runs.
var spinnerFrames = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

// provisionSteps are the steps in the order they run, with what each does.
// "login" only exists in browser mode, and is shown only while it runs.
var provisionSteps = []struct{ key, label string }{
	{"login", "sign in to Discord in the Chrome window"},
	{"create", "create the application"},
	{"bot", "add its bot user"},
	{"intent", "turn on Message Content Intent"},
	{"token", "make a bot token"},
	{"authorize", "add it to the server"},
}

// startAuto leaves the token form for the automatic one, or for the login
// first when no Discord login is connected.
func (m DiscordPageModel) startAuto() (DiscordPageModel, tea.Cmd) {
	name := ""
	if m.Form != nil {
		name = m.Form.value(discordFieldName)
	}
	m.Form, m.Error, m.Notice = nil, "", ""
	if !m.Account.Connected {
		m.Login, m.autoName = newDiscordLoginForm(), name
		return m, nil
	}
	return m.openAuto(name)
}

func (m DiscordPageModel) openAuto(name string) (DiscordPageModel, tea.Cmd) {
	m.Auto = newDiscordAutoForm(m.freeSessions(), name)
	conn := m.Conn
	return m, func() tea.Msg {
		if conn == nil {
			return discordServersMsg{Err: errors.New("daemon connection unavailable")}
		}
		servers, err := daemon.ListDiscordAccountGuilds(context.Background(), conn)
		if servers == nil && err == nil {
			servers = []daemon.DiscordAccountGuild{}
		}
		return discordServersMsg{Servers: servers, Err: err}
	}
}

// accountCmd connects (a token, or browser mode) or forgets the login.
func (m DiscordPageModel) accountCmd(token string, browser, then bool) (DiscordPageModel, tea.Cmd) {
	m.Error, m.Notice, m.Saving = "", "", true
	m.Generation = nextPageGeneration()
	conn, gen := m.Conn, m.Generation
	return m, func() tea.Msg {
		if conn == nil {
			return discordAccountMsg{Gen: gen, Err: errors.New("daemon connection unavailable")}
		}
		var account daemon.DiscordAccount
		var err error
		switch {
		case browser:
			account, err = daemon.ConnectDiscordAccountInBrowser(context.Background(), conn)
		case token != "":
			account, err = daemon.ConnectDiscordAccount(context.Background(), conn, token)
		default:
			account, err = daemon.ForgetDiscordAccount(context.Background(), conn)
		}
		return discordAccountMsg{Gen: gen, Account: account, Err: err, Then: then}
	}
}

// provisionCmd starts, reads, answers or cancels the provision.
func (m DiscordPageModel) provisionCmd(do func(context.Context, *daemon.Connection) (daemon.DiscordProvision, error)) tea.Cmd {
	conn, gen := m.Conn, m.Generation
	return func() tea.Msg {
		if conn == nil {
			return discordProvisionMsg{Gen: gen, Err: errors.New("daemon connection unavailable")}
		}
		p, err := do(context.Background(), conn)
		return discordProvisionMsg{Gen: gen, Provision: p, Err: err}
	}
}

func (m DiscordPageModel) provisionTick() tea.Cmd {
	ticker := m.ticker
	return tea.Tick(provisionPoll, func(time.Time) tea.Msg { return discordProvisionTickMsg{ticker} })
}

// updateProvision takes the flow's replies and ticks; handled is false for
// any other message.
func (m DiscordPageModel) updateProvision(msg tea.Msg) (DiscordPageModel, tea.Cmd, bool) {
	switch msg := msg.(type) {
	case discordAccountMsg:
		if !m.settle(msg.Gen, msg.Err, &m.Saving) {
			return m, nil, true
		}
		m.Account, m.Login = msg.Account, nil
		if !msg.Then {
			m.Notice = "Forgot your Discord login. Bots keep running."
			return m, nil, true
		}
		m.Notice = "Signed in as @" + msg.Account.Username + "."
		next, cmd := m.openAuto(m.autoName)
		return next, cmd, true
	case discordServersMsg:
		if m.Auto != nil {
			m.Auto.Servers = msg.Servers
			if msg.Err != nil {
				m.Auto.ServerErr = msg.Err.Error()
			}
		}
		return m, nil, true
	case discordProvisionMsg:
		if msg.Gen != m.Generation {
			return m, nil, true
		}
		m.Saving = false
		if msg.Err != nil {
			m.Error = msg.Err.Error()
			return m, nil, true
		}
		started := m.Provision == nil
		p := msg.Provision
		m.Provision, m.Auto = &p, nil
		if p.State == "mfa" && m.mfa == nil {
			input := newField()
			input.CharLimit, input.Placeholder = 8, "6-digit code"
			input.SetWidth(16)
			input.Focus()
			m.mfa = &input
		} else if p.State != "mfa" {
			m.mfa = nil
		}
		var cmds []tea.Cmd
		if started {
			cmds = append(cmds, m.provisionTick())
		}
		if p.Bot != nil && !slices.ContainsFunc(m.Bots, func(b daemon.DiscordBot) bool { return b.ID == p.Bot.ID }) {
			// The bot exists now; list it behind the progress view.
			m.Generation = nextPageGeneration()
			cmds = append(cmds, m.loadCmd(m.Generation, false))
		}
		return m, tea.Batch(cmds...), true
	case discordProvisionTickMsg:
		if msg.ticker != m.ticker || m.Provision == nil || !provisionActive(*m.Provision) {
			return m, nil, true
		}
		m.spin++
		if m.Saving {
			return m, m.provisionTick(), true
		}
		id := m.Provision.ID
		return m, tea.Batch(m.provisionTick(), m.provisionCmd(func(ctx context.Context, conn *daemon.Connection) (daemon.DiscordProvision, error) {
			return daemon.GetDiscordProvision(ctx, conn, id)
		})), true
	}
	return m, nil, false
}

func provisionActive(p daemon.DiscordProvision) bool { return p.State == "running" || p.State == "mfa" }

func (m DiscordPageModel) loginKey(msg tea.KeyPressMsg) (DiscordPageModel, tea.Cmd) {
	if msg.String() == "esc" {
		m.Login, m.Error = nil, ""
		return m, nil
	}
	if m.Saving {
		return m, nil
	}
	if msg.String() == "ctrl+b" {
		m.Login.browser = !m.Login.browser
		m.Error = ""
		return m, nil
	}
	submit, cmd := m.Login.update(msg)
	if !submit {
		return m, cmd
	}
	if m.Login.browser {
		return m.accountCmd("", true, true)
	}
	token := m.Login.value(discordFieldLogin)
	if token == "" {
		m.Error = "paste your Discord user token first, or press ctrl+b to sign in with a browser"
		return m, nil
	}
	return m.accountCmd(token, false, true)
}

func (m DiscordPageModel) autoKey(msg tea.KeyPressMsg) (DiscordPageModel, tea.Cmd) {
	if m.Saving {
		// The bot may be on its way; its progress takes over when it answers.
		return m, nil
	}
	switch msg.String() {
	case "esc":
		m.Auto, m.Error = nil, ""
		return m, nil
	case "ctrl+n":
		choice := m.Auto.sessionChoice
		name := m.Auto.value(discordFieldName)
		m.Auto, m.Error = nil, ""
		m.Form = newDiscordForm(nil, choice)
		m.Form.Inputs[discordFieldName].SetValue(name)
		return m, nil
	}
	submit, cmd := m.Auto.update(msg)
	if !submit {
		return m, cmd
	}
	name, err := m.Auto.request()
	if err != nil {
		m.Error = err.Error()
		return m, nil
	}
	return m.startProvision(m.Auto.Chosen, name, m.Auto.Server, m.Auto.serverLabel())
}

func (m DiscordPageModel) startProvision(session, name, server, serverName string) (DiscordPageModel, tea.Cmd) {
	m.Error, m.Notice, m.Saving = "", "", true
	m.Provision, m.mfa, m.spin = nil, nil, 0
	m.provisionServer = ""
	if server != "" {
		m.provisionServer = serverName
	}
	m.provisionRetry = [3]string{session, name, server}
	m.Generation = nextPageGeneration()
	return m, m.provisionCmd(func(ctx context.Context, conn *daemon.Connection) (daemon.DiscordProvision, error) {
		return daemon.StartDiscordProvision(ctx, conn, session, name, server)
	})
}

// provisionKey drives the progress view: a code while Discord asks for one,
// esc cancels while it runs, and the way on once it ends.
func (m DiscordPageModel) provisionKey(msg tea.KeyPressMsg) (DiscordPageModel, tea.Cmd) {
	p := *m.Provision
	key := msg.String()
	if m.Saving && key != "esc" {
		return m, nil
	}
	switch {
	case key == "esc" && provisionActive(p):
		m.Saving, m.Generation = true, nextPageGeneration()
		m.Notice = "Cancelled creating " + p.Name + "."
		return m, m.provisionCmd(func(ctx context.Context, conn *daemon.Connection) (daemon.DiscordProvision, error) {
			return daemon.CancelDiscordProvision(ctx, conn, p.ID)
		})
	case key == "esc" || (key == "enter" && p.State != "mfa"):
		return m.closeProvision()
	case p.State == "mfa" && key == "enter":
		code := strings.TrimSpace(m.mfa.Value())
		if code == "" {
			m.Error = "type the code from your authenticator app"
			return m, nil
		}
		m.mfa.SetValue("")
		m.Error, m.Saving, m.Generation = "", true, nextPageGeneration()
		return m, m.provisionCmd(func(ctx context.Context, conn *daemon.Connection) (daemon.DiscordProvision, error) {
			return daemon.AnswerDiscordMFA(ctx, conn, p.ID, code)
		})
	case p.State == "mfa":
		next, cmd := m.mfa.Update(msg)
		*m.mfa = next
		return m, cmd
	case key == "ctrl+l" && p.Code == "captcha":
		m.Error, m.Notice = "", "Developer portal link copied."
		return m, CopyText(p.PortalURL)
	case key == "ctrl+l" && p.Bot != nil && p.Bot.Invite != "":
		m.Error, m.Notice = "", "Invite link copied. Open it in a browser and pick a server."
		return m, CopyText(p.Bot.Invite)
	case key == "ctrl+o" && p.State == "failed" && p.Bot == nil:
		// Make it by hand in the portal and paste its token.
		choice := m.freeSessions()
		if slices.ContainsFunc(choice.Sessions, func(s daemon.Session) bool { return s.ID == p.SessionID }) {
			choice.Chosen = p.SessionID
		}
		m.Provision, m.Error = nil, ""
		m.Form = newDiscordForm(nil, choice)
		m.Form.Inputs[discordFieldName].SetValue(p.Name)
		return m, nil
	case key == "ctrl+r" && p.State == "failed" && p.Bot == nil:
		r := m.provisionRetry
		return m.startProvision(r[0], r[1], r[2], m.provisionServer)
	}
	return m, nil
}

// closeProvision leaves the progress view on the bot it made, if any.
func (m DiscordPageModel) closeProvision() (DiscordPageModel, tea.Cmd) {
	p := *m.Provision
	m.Provision, m.mfa, m.Error = nil, nil, ""
	if p.Bot == nil {
		return m, nil
	}
	m.selectRow(p.Bot.ID)
	if p.State == "done" {
		m.Notice = p.Name + " is ready and connecting. Press enter to choose its channels."
	}
	m.Loading, m.Generation = true, nextPageGeneration()
	return m, m.loadCmd(m.Generation, false)
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

// provisionRows are the progress view in the list's place.
func (m DiscordPageModel) provisionRows(width int) []string {
	p := *m.Provision
	rows := []string{DefaultStyles.Bold.Render("creating " + p.Name), DefaultStyles.Faint.Render("for " + sessionLabel(m.Sessions, p.SessionID, m.SessionID)), ""}
	current := slices.IndexFunc(provisionSteps, func(s struct{ key, label string }) bool { return s.key == p.Step })
	for i, step := range provisionSteps {
		label := step.label
		if step.key == "login" && i != current {
			// Signing in happens in the window, not in the step list; a run
			// that never needed it should not show it at all.
			continue
		}
		if step.key == "authorize" {
			if m.provisionServer == "" {
				continue
			}
			label = "add it to " + m.provisionServer
		}
		var mark string
		switch {
		case p.State == "done" || i < current || (p.Bot != nil && step.key != "authorize"):
			mark = DefaultStyles.Success.Render("✓")
		case i == current && p.State == "failed":
			mark, label = DefaultStyles.Error.Render("✗"), DefaultStyles.Error.Render(label)
		case i == current && p.State == "mfa":
			mark, label = DefaultStyles.Warning.Render("?"), label+DefaultStyles.Warning.Render(" · waiting for your code")
		case i == current && p.State == "running":
			mark, label = DefaultStyles.Prompt.Render(spinnerFrames[m.spin%len(spinnerFrames)]), DefaultStyles.Bold.Render(label)
		default:
			mark, label = DefaultStyles.Faint.Render("·"), DefaultStyles.Faint.Render(label)
		}
		rows = append(rows, "  "+mark+"  "+label)
	}
	rows = append(rows, "")
	wrap := func(style func(...string) string, text string) {
		for _, l := range svWrap(text, max(1, width-4), 5) {
			rows = append(rows, "  "+style(l))
		}
	}
	switch p.State {
	case "mfa":
		wrap(DefaultStyles.Bold.Render, "Discord asks for your two-factor code.")
		if len(p.Methods) > 0 {
			wrap(DefaultStyles.Faint.Render, "accepted: "+strings.Join(p.Methods, ", "))
		}
		rows = append(rows, formRow(true, "code", 8, m.mfa.View(), width))
		if p.MFAError != "" {
			wrap(DefaultStyles.Error.Render, p.MFAError)
		}
	case "done":
		as := ""
		if p.Bot != nil && p.Bot.Username != "" {
			as = " as @" + p.Bot.Username
		}
		wrap(DefaultStyles.Success.Render, p.Name+" is ready"+as+". It is connecting now; you are its owner, so you can DM it.")
		if m.provisionServer == "" {
			wrap(DefaultStyles.Faint.Render, "Copy its invite link with ctrl+l to add it to a server.")
		}
	case "failed":
		wrap(DefaultStyles.Error.Render, cmp.Or(p.Error, "Discord refused."))
		switch {
		case p.Bot != nil:
			wrap(DefaultStyles.Faint.Render, "The bot was created but not added to the server. Copy its invite link with ctrl+l and open it to add it yourself.")
		case p.Code == "captcha":
			wrap(DefaultStyles.Faint.Render, "Discord wants a captcha, which albedo can't solve. Make the bot in the developer portal (ctrl+l copies the link), then paste its token with ctrl+o.")
		case p.Code == "unauthorized":
			wrap(DefaultStyles.Faint.Render, "albedo could not use your Discord login. Sign in to Discord in the browser window, or forget the login with ctrl+u on the bot list and connect it again.")
		}
	case "cancelled":
		wrap(DefaultStyles.Faint.Render, "Cancelled. Nothing more will be created.")
	}
	return rows
}

// provisionHints are the progress view's keys.
func (m DiscordPageModel) provisionHints() []hint {
	p := *m.Provision
	switch {
	case p.State == "mfa":
		return []hint{{"enter", "send code"}, {"esc", "cancel"}}
	case p.State == "running":
		return []hint{{"esc", "cancel"}}
	case p.State == "failed" && p.Code == "captcha":
		return []hint{{"ctrl+l", "copy portal link"}, {"ctrl+o", "paste a token"}, {"esc", "back"}}
	case p.State == "failed" && p.Bot == nil:
		return []hint{{"ctrl+r", "try again"}, {"esc", "back"}}
	case p.Bot != nil:
		return []hint{{"enter", "show the bot"}, {"ctrl+l", "copy invite"}, {"esc", "back"}}
	}
	return []hint{{"esc", "back"}}
}
