// The Discord adapter's wire shapes: which method, content type and body each
// change sends, and that a malformed bot is refused instead of shown. A real
// daemon only ever answers well, so a controlled peer covers the refusals.
package daemon

import (
	"io"
	"net/http"
	"strings"
	"testing"
)

const discordBotJSON = `{"id":"b1","session_id":"s","name":"albedo","owner_id":"80351110224678912","enabled":true,"revision":4,"state":"online","detail":null,"user":{"id":"1100","username":"albedo-infra"},"application_id":"1100","invite_url":"https://discord.com/oauth2/authorize?client_id=1100","channels":2,"allowed":1,"requests":0}`

func TestDiscordChangesSendTheirContractShapes(t *testing.T) {
	var seen []string
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		seen = append(seen, r.Method+" "+r.URL.String()+" "+r.Header.Get("Content-Type")+" "+string(body))
		switch {
		case r.Method == http.MethodPatch:
			_, _ = io.WriteString(w, discordBotJSON)
		case r.Method == http.MethodDelete && strings.HasPrefix(r.URL.Path, "/extensions/discord/bots/b1/requests/"):
			_, _ = io.WriteString(w, `{"deleted":"70351110224678914"}`)
		case r.Method == http.MethodDelete:
			_, _ = io.WriteString(w, `{"deleted":"b1"}`)
		case strings.Contains(r.URL.Path, "/channels/"):
			_, _ = io.WriteString(w, `{"channel_id":"c1","delivery":"tool","mentions_only":true}`)
		default:
			_, _ = io.WriteString(w, `{"user_id":"70351110224678914","name":"kestrel","added_at":1}`)
		}
	})
	enabled := false
	if bot, err := EditDiscordBot(t.Context(), conn, "b1", DiscordBotPatch{Revision: 4, Enabled: &enabled}); err != nil || bot.Username != "albedo-infra" || bot.Invite == "" {
		t.Fatalf("edit = %+v, %v", bot, err)
	}
	if err := DeleteDiscordBot(t.Context(), conn, "b1", 4); err != nil {
		t.Fatal(err)
	}
	change := DiscordChannelChange{GuildID: "g1", GuildName: "lab", ChannelID: "c1", ChannelName: "albedos", Delivery: "tool", MentionsOnly: true}
	if channel, err := SetDiscordChannel(t.Context(), conn, "b1", change); err != nil || channel.Delivery != "tool" || !channel.MentionsOnly {
		t.Fatalf("set channel = %+v, %v", channel, err)
	}
	if person, err := AllowDiscordDM(t.Context(), conn, "b1", "70351110224678914", ""); err != nil || person.Name != "kestrel" {
		t.Fatalf("allow = %+v, %v", person, err)
	}
	if err := DismissDiscordRequest(t.Context(), conn, "b1", "70351110224678914"); err != nil {
		t.Fatal(err)
	}
	want := []string{
		`PATCH /extensions/discord/bots/b1 application/merge-patch+json {"enabled":false,"revision":4}`,
		`DELETE /extensions/discord/bots/b1?revision=4 application/json `,
		`PUT /extensions/discord/bots/b1/channels/c1 application/json {"channel_name":"albedos","delivery":"tool","guild_id":"g1","guild_name":"lab","mentions_only":true}`,
		`PUT /extensions/discord/bots/b1/dms/70351110224678914 application/json {"name":null}`,
		`DELETE /extensions/discord/bots/b1/requests/70351110224678914 application/json `,
	}
	if strings.Join(seen, "\n") != strings.Join(want, "\n") {
		t.Fatalf("requests:\n%s\nwant:\n%s", strings.Join(seen, "\n"), strings.Join(want, "\n"))
	}
}

func TestDiscordBotsRefuseAnUnknownState(t *testing.T) {
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `{"items":[`+strings.Replace(discordBotJSON, `"online"`, `"sleeping"`, 1)+`]}`)
	})
	if bots, err := ListDiscordBots(t.Context(), conn); err == nil {
		t.Fatalf("a bot in an unknown state was listed: %+v", bots)
	}
}

func TestDiscordDeletionMustNameWhatItDeleted(t *testing.T) {
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `{"deleted":"someone-else"}`)
	})
	if err := RemoveDiscordDM(t.Context(), conn, "b1", "90351110224678913"); err == nil {
		t.Fatal("a deletion of another person was accepted")
	}
}

func TestDiscordProvisionAndAccountShapes(t *testing.T) {
	var seen []string
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		seen = append(seen, r.Method+" "+r.URL.Path+" "+string(body))
		switch {
		case strings.HasSuffix(r.URL.Path, "/account"):
			_, _ = io.WriteString(w, `{"connected":true,"user":{"id":"80351110224678912","username":"ana"}}`)
		case r.Method == http.MethodPost && r.URL.Path == "/extensions/discord/provisions":
			w.WriteHeader(http.StatusAccepted)
			_, _ = io.WriteString(w, `{"id":"p1","session_id":"s","name":"albedo","state":"done","step":"authorize","methods":[],"mfa_error":null,"error":null,"code":null,"bot":`+discordBotJSON+`,"portal_url":"https://discord.com/developers/applications"}`)
		default:
			_, _ = io.WriteString(w, `{"id":"p1","session_id":"s","name":"albedo","state":"mfa","step":"token","methods":["totp"],"mfa_error":"wrong code","error":null,"code":null,"bot":null,"portal_url":"https://discord.com/developers/applications"}`)
		}
	})
	if account, err := ConnectDiscordAccount(t.Context(), conn, "user.token"); err != nil || account.Username != "ana" {
		t.Fatalf("connect = %+v, %v", account, err)
	}
	p, err := StartDiscordProvision(t.Context(), conn, "s", "albedo", "")
	if err != nil || p.State != "done" || p.Bot == nil || p.Bot.ID != "b1" {
		t.Fatalf("start = %+v, %v", p, err)
	}
	if p, err = AnswerDiscordMFA(t.Context(), conn, "p1", "123456"); err != nil || p.MFAError != "wrong code" || p.Methods[0] != "totp" {
		t.Fatalf("mfa = %+v, %v", p, err)
	}
	if _, err = CancelDiscordProvision(t.Context(), conn, "p1"); err != nil {
		t.Fatal(err)
	}
	want := []string{
		`PUT /extensions/discord/account {"token":"user.token"}`,
		`POST /extensions/discord/provisions {"guild_id":null,"name":"albedo","session_id":"s"}`,
		`POST /extensions/discord/provisions/p1/mfa {"code":"123456"}`,
		`DELETE /extensions/discord/provisions/p1 `,
	}
	if strings.Join(seen, "\n") != strings.Join(want, "\n") {
		t.Fatalf("requests:\n%s", strings.Join(seen, "\n"))
	}
}

func TestDiscordAccountMustAgreeWithItsUser(t *testing.T) {
	conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `{"connected":true,"user":null}`)
	})
	if account, err := GetDiscordAccount(t.Context(), conn); err == nil {
		t.Fatalf("a connected account without a user was accepted: %+v", account)
	}
}
