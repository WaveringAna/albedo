package tui

import (
	"albedo/cli/internal/daemon"
	"errors"
	"regexp"
	"strings"
	"unicode/utf8"

	tea "charm.land/bubbletea/v2"
)

// discordForm adds a session's bot or edits one on a single screen: its
// name, the session it speaks for, its token, and the Discord user it
// belongs to. The session is fixed once the bot exists, and the stored token
// is never shown; a new one replaces it.
type discordForm struct {
	form
	// Editing is the bot being edited; nil for a new bot.
	Editing *daemon.DiscordBot
	sessionChoice
}

var discordFields = []string{discordFieldName, discordFieldSession, discordFieldToken, discordFieldOwner}

func newDiscordForm(editing *daemon.DiscordBot, choice sessionChoice) *discordForm {
	f := &discordForm{form: newForm(discordFields, discordFieldToken), sessionChoice: choice}
	f.Inputs[discordFieldName].Placeholder = "albedo"
	f.Inputs[discordFieldSession].Placeholder = "type to filter"
	f.Inputs[discordFieldToken].Placeholder = "paste the bot token"
	f.Inputs[discordFieldOwner].Placeholder = "e.g. 80351110224678912"
	if editing != nil {
		bot := *editing
		f.Editing, f.Chosen = &bot, bot.SessionID
		f.Inputs[discordFieldName].SetValue(bot.Name)
		f.Inputs[discordFieldOwner].SetValue(bot.OwnerID)
		f.Inputs[discordFieldToken].Placeholder = "stored · paste a new one to replace it"
	}
	f.focus(f.current())
	return f
}

func (f *discordForm) current() string { return discordFields[f.Focus] }

// update handles one key or paste; submit reports that the form should be saved.
func (f *discordForm) update(msg tea.Msg) (submit bool, cmd tea.Cmd) {
	if submit, handled := f.key(msg, discordFields, 0); handled {
		if f.Editing != nil && f.current() == discordFieldSession {
			// The session is fixed; step over it the way the key moved.
			f.key(msg, discordFields, 0)
		}
		return submit, nil
	}
	query := f.Inputs[discordFieldSession].Value()
	if key, ok := msg.(tea.KeyPressMsg); ok && f.current() == discordFieldSession && f.step(query, key.String()) {
		return false, nil
	}
	input := f.Inputs[f.current()]
	next, cmd := input.Update(msg)
	*input = next
	if f.current() == discordFieldSession {
		f.follow(input.Value())
	}
	return false, cmd
}

// create is the new bot the form describes, once it is valid.
func (f *discordForm) create() (daemon.DiscordBotCreate, error) {
	name, token, owner := f.value(discordFieldName), f.value(discordFieldToken), f.value(discordFieldOwner)
	switch {
	case !validDiscordName(name):
		return daemon.DiscordBotCreate{}, errors.New("name: 1–64 characters")
	case f.Chosen == "":
		return daemon.DiscordBotCreate{}, errors.New("choose the session this bot speaks for")
	case !discordToken.MatchString(token):
		return daemon.DiscordBotCreate{}, errors.New("token: paste the bot token from the developer portal (three parts joined by dots)")
	case !discordUserID.MatchString(owner):
		return daemon.DiscordBotCreate{}, errors.New("your Discord user ID: 17–20 digits")
	}
	return daemon.DiscordBotCreate{SessionID: f.Chosen, Name: name, Token: token, OwnerID: owner}, nil
}

// patch is what the form changes on the bot; nil when nothing changed.
func (f *discordForm) patch() (*daemon.DiscordBotPatch, error) {
	name, token, owner := f.value(discordFieldName), f.value(discordFieldToken), f.value(discordFieldOwner)
	switch {
	case !validDiscordName(name):
		return nil, errors.New("name: 1–64 characters")
	case token != "" && !discordToken.MatchString(token):
		return nil, errors.New("token: three parts joined by dots, or blank to keep the stored one")
	case !discordUserID.MatchString(owner):
		return nil, errors.New("your Discord user ID: 17–20 digits")
	}
	bot := f.Editing
	patch := daemon.DiscordBotPatch{Revision: bot.Revision}
	changed := false
	if name != bot.Name {
		patch.Name, changed = &name, true
	}
	if token != "" {
		patch.Token, changed = &token, true
	}
	if owner != bot.OwnerID {
		patch.OwnerID, changed = &owner, true
	}
	if !changed {
		return nil, nil
	}
	return &patch, nil
}

// view is the form's rows, with the focused field's help under it; its keys
// are the footer.
func (f *discordForm) view(width int) []string {
	title := "add a discord bot"
	if f.Editing != nil {
		title = "edit " + f.Editing.Name
	}
	f.fit(width - 17)
	rows := []string{DefaultStyles.Bold.Render(title)}
	indent := strings.Repeat(" ", 16)
	for i, key := range discordFields {
		value := f.Inputs[key].View()
		switch {
		case key == discordFieldSession && f.Editing != nil:
			value = DefaultStyles.Faint.Render(f.label())
		case key == discordFieldSession && i != f.Focus:
			value = f.label()
		}
		rows = append(rows, formRow(i == f.Focus, discordFieldLabels[key], 14, value, width))
		if i != f.Focus {
			continue
		}
		if key == discordFieldSession && f.Editing == nil {
			rows = append(rows, f.rows(f.Inputs[discordFieldSession].Value(), indent, width)...)
		}
		for _, line := range svWrap(f.help(), max(1, width-len(indent)), 3) {
			rows = append(rows, indent+DefaultStyles.Faint.Render(line))
		}
	}
	return rows
}

// help explains the focused field where to find what it asks for.
func (f *discordForm) help() string {
	switch f.current() {
	case discordFieldName:
		return "what you call this bot here; Discord shows the name set in the developer portal"
	case discordFieldSession:
		return "the session that reads its channels and DMs and replies through it; one bot per session"
	case discordFieldToken:
		if f.Editing != nil {
			return "blank keeps the stored token; a new one restarts the bot"
		}
		return "discord.com/developers/applications → your app → Bot → Reset Token; turn on Message Content Intent on the same page"
	}
	return "you can always DM the bot. Discord → Settings → Advanced → Developer Mode, then right-click yourself → Copy User ID"
}

// footer offers the keys every form shares, and ←→ on the session picker.
func (f *discordForm) footer(width int) string {
	var own []hint
	if f.current() == discordFieldSession && f.Editing == nil {
		own = []hint{{"←→", "choose"}}
	}
	keys := append(own, hint{"ctrl+s", "save"})
	if f.Editing == nil {
		keys = append(keys, hint{"ctrl+n", "create automatically"})
	}
	keys = append(keys, hint{"enter", "next"}, hint{"tab/↑↓", "move"}, hint{"esc", "cancel"})
	return footerLine(width, keys, "", false)
}

// discordPersonForm lets one more person DM the bot: their user ID, and a
// name to know them by, which Discord fills in when left blank.
type discordPersonForm struct {
	form
}

var personFields = []string{discordFieldUser, discordFieldNick}

func newDiscordPersonForm() *discordPersonForm {
	f := &discordPersonForm{form: newForm(personFields)}
	f.Inputs[discordFieldUser].Placeholder = "e.g. 80351110224678912"
	f.Inputs[discordFieldNick].Placeholder = "optional · looked up on Discord when blank"
	f.focus(discordFieldUser)
	return f
}

func (f *discordPersonForm) update(msg tea.Msg) (submit bool, cmd tea.Cmd) {
	if submit, handled := f.key(msg, personFields, 0); handled {
		return submit, nil
	}
	input := f.Inputs[personFields[f.Focus]]
	next, cmd := input.Update(msg)
	*input = next
	return false, cmd
}

// person is the user ID and name to allow, once valid.
func (f *discordPersonForm) person() (id, name string, err error) {
	id, name = f.value(discordFieldUser), f.value(discordFieldNick)
	switch {
	case !discordUserID.MatchString(id):
		return "", "", errors.New("user ID: 17–20 digits (Developer Mode → right-click them → Copy User ID)")
	case utf8.RuneCountInString(name) > 64:
		return "", "", errors.New("name: at most 64 characters")
	}
	return id, name, nil
}

func (f *discordPersonForm) view(width int) []string {
	f.fit(width - 17)
	rows := []string{DefaultStyles.Bold.Render("let someone DM this bot")}
	for i, key := range personFields {
		rows = append(rows, formRow(i == f.Focus, discordFieldLabels[key], 14, f.Inputs[key].View(), width))
	}
	note := "Turn on Developer Mode in Discord (Settings → Advanced), right-click them → Copy User ID."
	rows = append(rows, "")
	for _, line := range svWrap(note, max(1, width-2), 3) {
		rows = append(rows, "  "+DefaultStyles.Faint.Render(line))
	}
	return rows
}

func (f *discordPersonForm) footer(width int) string {
	return footerLine(width, []hint{{"ctrl+s", "allow"}, {"enter", "next"}, {"tab/↑↓", "move"}, {"esc", "cancel"}}, "", false)
}

func validDiscordName(name string) bool {
	n := utf8.RuneCountInString(name)
	return n >= 1 && n <= 64
}

const (
	discordFieldName    = "name"
	discordFieldSession = "session"
	discordFieldToken   = "token"
	discordFieldOwner   = "owner"
	discordFieldUser    = "user"
	discordFieldNick    = "nick"
	discordFieldLogin   = "login"
	discordFieldServer  = "server"
)

var discordFieldLabels = map[string]string{
	discordFieldName:    "name",
	discordFieldSession: "session",
	discordFieldToken:   "bot token",
	discordFieldOwner:   "your user ID",
	discordFieldUser:    "user ID",
	discordFieldNick:    "name",
	discordFieldLogin:   "user token",
	discordFieldServer:  "server",
}

var (
	discordToken  = regexp.MustCompile(`^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$`)
	discordUserID = regexp.MustCompile(`^[0-9]{17,20}$`)
)
