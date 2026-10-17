package daemon

import (
	"context"
	"io"
	"net/http"
	"slices"

	"albedo/cli/internal/daemon/protocol"
)

// DiscordBot is a session's Discord bot as the daemon reports it, without its
// token, which never leaves the daemon.
type DiscordBot struct {
	ID, SessionID, Name, OwnerID string
	// State is disabled, connecting, online, reconnecting or failed; Detail
	// says why when the daemon knows.
	State, Detail                           string
	UserID, Username, ApplicationID, Invite string
	Revision                                int64
	Channels, Allowed, Requests             int
	Enabled                                 bool
}

// DiscordGuild is one server the bot is in, with the channels it can see.
type DiscordGuild struct {
	ID, Name string
	Channels []DiscordChannel
}

// DiscordChannel is a channel and how its messages reach the session:
// Delivery is off, turn (after the running turn) or tool (after the current
// tool call).
type DiscordChannel struct {
	ID, Name, ParentID, Delivery string
	Type, Position               int
	MentionsOnly                 bool
}

// DiscordChannelChange sets one channel's delivery; the names travel with it
// so the daemon can list the channel while the bot is offline.
type DiscordChannelChange struct {
	GuildID, GuildName, ChannelID, ChannelName, Delivery string
	MentionsOnly                                         bool
}

// DiscordPerson is someone who may DM the bot. AddedAt is unix milliseconds
// and zero for the owner.
type DiscordPerson struct {
	UserID, Name string
	AddedAt      int64
}

// DiscordRequest is someone whose DMs were refused because they are not on
// the allow list.
type DiscordRequest struct {
	UserID, Username, Preview string
	LastAt                    int64
	Count                     int
}

type DiscordDMs struct {
	Owner    DiscordPerson
	Allowed  []DiscordPerson
	Requests []DiscordRequest
}

type DiscordBotCreate = protocol.DiscordBotCreate
type DiscordBotPatch = protocol.DiscordBotPatch

var discordStates = []string{"disabled", "connecting", "online", "reconnecting", "failed"}
var discordDeliveries = []string{"off", "turn", "tool"}

func discordBot(w protocol.DiscordBot) (DiscordBot, error) {
	if w.ID == "" || w.SessionID == "" || !slices.Contains(discordStates, w.State) {
		return DiscordBot{}, fieldError("discord bot")
	}
	bot := DiscordBot{
		ID: w.ID, SessionID: w.SessionID, Name: w.Name, OwnerID: w.OwnerID, State: w.State, Detail: value(w.Detail),
		ApplicationID: value(w.ApplicationID), Invite: value(w.InviteURL), Revision: w.Revision,
		Channels: int(w.Channels), Allowed: int(w.Allowed), Requests: int(w.Requests), Enabled: w.Enabled,
	}
	if w.User != nil {
		bot.UserID, bot.Username = w.User.ID, w.User.Username
	}
	return bot, nil
}

// ListDiscordBots lists the bots of every session, ordered by session and name.
func ListDiscordBots(ctx context.Context, conn *Connection) ([]DiscordBot, error) {
	var page protocol.DiscordBotPage
	err := executeRead(ctx, conn, operation{Name: "list discord bots", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewListDiscordBotsRequest(base)
	}, Policy: readRecovery}, func(data []byte) error { return decodeRequired(data, &page) })
	if err != nil {
		return nil, err
	}
	bots := make([]DiscordBot, 0, len(page.Items))
	for _, w := range page.Items {
		bot, err := discordBot(w)
		if err != nil {
			return nil, &ProtocolError{Code: "invalid_response", Operation: "list discord bots", Field: "items", Cause: err}
		}
		bots = append(bots, bot)
	}
	return bots, nil
}

// botChange runs a mutation that answers with the bot.
func botChange(ctx context.Context, conn *Connection, op operation, status int) (DiscordBot, error) {
	var bot DiscordBot
	err := executeMutation(ctx, conn, op, []int{status}, func(data []byte, _ int) error {
		var w protocol.DiscordBot
		if err := decodeRequired(data, &w); err != nil {
			return err
		}
		var err error
		bot, err = discordBot(w)
		return err
	})
	return bot, err
}

// CreateDiscordBot gives a session its bot; a session has at most one.
func CreateDiscordBot(ctx context.Context, conn *Connection, request DiscordBotCreate) (DiscordBot, error) {
	return botChange(ctx, conn, operation{Name: "create discord bot", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewCreateDiscordBotRequest(base, request)
	}, Body: request, Policy: noRecovery}, http.StatusCreated)
}

// EditDiscordBot changes a bot at the revision it was read at; a stale
// revision is refused.
func EditDiscordBot(ctx context.Context, conn *Connection, id string, patch DiscordBotPatch) (DiscordBot, error) {
	return botChange(ctx, conn, operation{Name: "edit discord bot", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewPatchDiscordBotRequestWithApplicationMergePatchPlusJSONBody(base, id, patch)
	}, Headers: http.Header{"Content-Type": {"application/merge-patch+json"}}, Body: patch, Policy: noRecovery}, http.StatusOK)
}

// DeleteDiscordBot removes a bot with its channels and DM lists.
func DeleteDiscordBot(ctx context.Context, conn *Connection, id string, revision int64) error {
	return discordDeletion(ctx, conn, "delete discord bot", id, func(base string) (*http.Request, error) {
		return protocol.NewDeleteDiscordBotRequest(base, id, &protocol.DeleteDiscordBotParams{Revision: revision})
	})
}

// discordDeletion runs a DELETE that answers {"deleted": id}.
func discordDeletion(ctx context.Context, conn *Connection, name, id string, build func(string) (*http.Request, error)) error {
	return executeMutation(ctx, conn, operation{Name: name, BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return build(base)
	}, Policy: noRecovery}, []int{http.StatusOK}, func(data []byte, _ int) error {
		var w protocol.DiscordUserDeletion
		if err := decodeRequired(data, &w); err != nil {
			return err
		}
		if w.Deleted != id {
			return fieldError("deleted")
		}
		return nil
	})
}

// ListDiscordGuilds reads the servers and channels from the running bot; the
// daemon answers 503 bot_offline while it is not online.
func ListDiscordGuilds(ctx context.Context, conn *Connection, id string) ([]DiscordGuild, error) {
	var w protocol.DiscordGuildList
	err := executeRead(ctx, conn, operation{Name: "list discord channels", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewListDiscordGuildsRequest(base, id)
	}, Policy: readRecovery}, func(data []byte) error {
		if err := decodeRequired(data, &w); err != nil {
			return err
		}
		for _, guild := range w.Guilds {
			for _, channel := range guild.Channels {
				if !slices.Contains(discordDeliveries, channel.Delivery) {
					return fieldError("delivery")
				}
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	guilds := make([]DiscordGuild, len(w.Guilds))
	for i, g := range w.Guilds {
		guilds[i] = DiscordGuild{ID: g.ID, Name: g.Name, Channels: make([]DiscordChannel, len(g.Channels))}
		for j, c := range g.Channels {
			guilds[i].Channels[j] = DiscordChannel{ID: c.ID, Name: c.Name, ParentID: value(c.ParentID), Delivery: c.Delivery, Type: int(c.Type), Position: int(c.Position), MentionsOnly: c.MentionsOnly}
		}
	}
	return guilds, nil
}

// SetDiscordChannel sets how one channel reaches the session; off stops it.
func SetDiscordChannel(ctx context.Context, conn *Connection, botID string, change DiscordChannelChange) (DiscordChannel, error) {
	request := protocol.DiscordChannelSetting{Delivery: change.Delivery, MentionsOnly: change.MentionsOnly, GuildID: &change.GuildID, GuildName: &change.GuildName, ChannelName: &change.ChannelName}
	var result DiscordChannel
	err := executeMutation(ctx, conn, operation{Name: "set discord channel", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewPutDiscordChannelRequest(base, botID, change.ChannelID, request)
	}, Body: request, Policy: noRecovery}, []int{http.StatusOK}, func(data []byte, _ int) error {
		var w protocol.DiscordChannelState
		if err := decodeRequired(data, &w); err != nil {
			return err
		}
		if w.ChannelID != change.ChannelID || !slices.Contains(discordDeliveries, w.Delivery) {
			return fieldError("channel")
		}
		result = DiscordChannel{ID: w.ChannelID, Name: change.ChannelName, Delivery: w.Delivery, MentionsOnly: w.MentionsOnly}
		return nil
	})
	return result, err
}

// GetDiscordDMs reads who may DM the bot and who asked to; requests come
// newest first.
func GetDiscordDMs(ctx context.Context, conn *Connection, id string) (DiscordDMs, error) {
	var w protocol.DiscordDMs
	err := executeRead(ctx, conn, operation{Name: "read discord dms", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewGetDiscordDMsRequest(base, id)
	}, Policy: readRecovery}, func(data []byte) error {
		if err := decodeRequired(data, &w); err != nil {
			return err
		}
		if w.Owner.UserID == "" {
			return fieldError("owner")
		}
		return nil
	})
	if err != nil {
		return DiscordDMs{}, err
	}
	dms := DiscordDMs{Owner: DiscordPerson{UserID: w.Owner.UserID, Name: value(w.Owner.Name)}}
	for _, a := range w.Allowed {
		dms.Allowed = append(dms.Allowed, DiscordPerson{UserID: a.UserID, Name: value(a.Name), AddedAt: a.AddedAt})
	}
	for _, r := range w.Requests {
		dms.Requests = append(dms.Requests, DiscordRequest{UserID: r.UserID, Username: r.Username, Preview: r.Preview, LastAt: r.LastAt, Count: int(r.Count)})
	}
	return dms, nil
}

// AllowDiscordDM lets someone DM the bot and clears their request. An empty
// name asks the daemon to look it up on Discord.
func AllowDiscordDM(ctx context.Context, conn *Connection, botID, userID, name string) (DiscordPerson, error) {
	request := protocol.DiscordAllow{Name: optionalText(name)}
	var person DiscordPerson
	err := executeMutation(ctx, conn, operation{Name: "allow discord dm", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewPutDiscordDMRequest(base, botID, userID, request)
	}, Body: request, Policy: noRecovery}, []int{http.StatusOK}, func(data []byte, _ int) error {
		var w protocol.DiscordAllowed
		if err := decodeRequired(data, &w); err != nil {
			return err
		}
		if w.UserID != userID {
			return fieldError("user_id")
		}
		person = DiscordPerson{UserID: w.UserID, Name: value(w.Name), AddedAt: w.AddedAt}
		return nil
	})
	return person, err
}

// RemoveDiscordDM takes someone off the allow list; the owner stays.
func RemoveDiscordDM(ctx context.Context, conn *Connection, botID, userID string) error {
	return discordDeletion(ctx, conn, "remove discord dm", userID, func(base string) (*http.Request, error) {
		return protocol.NewDeleteDiscordDMRequest(base, botID, userID)
	})
}

// DismissDiscordRequest forgets a refused DM without allowing its sender.
func DismissDiscordRequest(ctx context.Context, conn *Connection, botID, userID string) error {
	return discordDeletion(ctx, conn, "dismiss discord dm request", userID, func(base string) (*http.Request, error) {
		return protocol.NewDeleteDiscordRequestRequest(base, botID, userID)
	})
}
