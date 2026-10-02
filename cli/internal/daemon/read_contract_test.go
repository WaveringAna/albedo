// A healthy daemon cannot emit missing fields or an unrelated page. Controlled
// peers exercise the adapter's rejection before those values reach any screen.
package daemon

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestNamedReadsRejectMalformedEnvelopesAndAcceptEmptyCurrentResponses(t *testing.T) {
	preview := func(ctx context.Context, conn *Connection) error {
		_, err := GetSessionPreview(ctx, conn, "s", 16)
		return err
	}
	tree := func(ctx context.Context, conn *Connection) error {
		_, err := GetSessionTree(ctx, conn, "s", 0, 50)
		return err
	}
	snapshot := func(ctx context.Context, conn *Connection) error {
		_, err := GetContextSnapshot(ctx, conn, "s")
		return err
	}
	contextPage := func(ctx context.Context, conn *Connection) error {
		_, err := GetContextPage(ctx, conn, "s", "history", 2)
		return err
	}
	for _, test := range []struct {
		name, body string
		read       func(context.Context, *Connection) error
		valid      bool
		status     int
	}{

		{"missing status flag", `{"phase":"resting","idle":true}`, func(ctx context.Context, conn *Connection) error {
			_, err := NewChatClient(conn, "s").GetStatus(ctx)
			return err
		}, false, 200},
		{"unknown status phase", `{"phase":"unknown","idle":true,"running":false}`, func(ctx context.Context, conn *Connection) error {
			_, err := NewChatClient(conn, "s").GetStatus(ctx)
			return err
		}, false, 200},
		{"model status phase", `{"phase":"model","idle":false,"running":true}`, func(ctx context.Context, conn *Connection) error {
			_, err := NewChatClient(conn, "s").GetStatus(ctx)
			return err
		}, true, 200},
		{"absent preview items", `{"total":0}`, preview, false, 200},
		{"null preview items", `{"items":null,"total":0}`, preview, false, 200},
		{"empty preview", `{"items":[],"total":0}`, preview, true, 200},
		{"preview missing type", `{"items":[{"preview":"message"}],"total":1}`, preview, false, 200},
		{"wrong success status", `{"items":[],"total":0}`, preview, false, 202},
		{"empty body", "", preview, false, 200},
		{"null body", "null", preview, false, 200},
		{"empty tree", `{"items":[],"nextCursor":null,"hasMore":false}`, tree, true, 200},
		{"missing tree cursor", `{"items":[],"hasMore":false}`, tree, false, 200},
		{"tree cannot advance", `{"items":[{"id":1,"type":"user","preview":"","timestamp":null}],"nextCursor":0,"hasMore":true}`, tree, false, 200},
		{"unordered tree", `{"items":[{"id":2,"type":"user","preview":"","timestamp":null},{"id":1,"type":"user","preview":"","timestamp":null}],"nextCursor":null,"hasMore":false}`, tree, false, 200},
		{"valid nullable tree", `{"items":[{"id":1,"type":"user","preview":"","timestamp":null}],"nextCursor":null,"hasMore":false}`, tree, true, 200},
		{"pending context", `{"state":"pending","reason":"No prepared turn"}`, snapshot, true, 200},
		{"pending missing reason", `{"state":"pending"}`, snapshot, false, 200},
		{"ready without optional metadata", `{"state":"ready","model":"m","sections":[],"compaction":{"status":"unknown"}}`, snapshot, true, 200},
		{"ready missing model", `{"state":"ready","sections":[],"compaction":{"status":"unknown"}}`, snapshot, false, 200},
		{"context wrong page", `{"section":"history","content":"","page":1,"pages":3}`, contextPage, false, 200},
		{"context wrong section", `{"section":"tools","content":"","page":2,"pages":3}`, contextPage, false, 200},
		{"context selected page", `{"section":"history","content":"","page":2,"pages":3}`, contextPage, true, 200},
		{"catalog missing revision", `{"workspace":"/tmp","extensions":{},"diagnostics":[],"candidates":[]}`, func(ctx context.Context, conn *Connection) error {
			_, err := GetCapabilityCatalog(ctx, conn, "s")
			return err
		}, false, 200},
		{"empty catalog", `{"workspace":"/tmp","revision":"revision","extensions":{},"diagnostics":[],"candidates":[]}`, func(ctx context.Context, conn *Connection) error {
			_, err := GetCapabilityCatalog(ctx, conn, "s")
			return err
		}, true, 200},
		{"bare detailed model", `["model"]`, func(ctx context.Context, conn *Connection) error {
			_, err := ListModels(ctx, conn, "openai", "")
			return err
		}, false, 200},
		{"optional model metadata", `[{"id":"model","context":null,"output":null}]`, func(ctx context.Context, conn *Connection) error {
			_, err := ListModels(ctx, conn, "openai", "")
			return err
		}, true, 200},
	} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/health" {
					_, _ = fmt.Fprint(w, `{"ok":true,"version":2,"capabilities":["session_tree","session_context"]}`)
					return
				}
				w.WriteHeader(test.status)
				_, _ = fmt.Fprint(w, test.body)
			}))
			defer server.Close()
			conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "token"}, nil)
			err := test.read(t.Context(), conn)
			if test.valid && err != nil {
				t.Fatalf("valid current response rejected: %v", err)
			}
			if !test.valid && err == nil {
				t.Fatal("malformed response reached caller")
			}
			if !test.valid && test.status == 200 {
				if _, ok := errors.AsType[*ProtocolError](err); !ok {
					t.Fatalf("malformed response lost protocol classification: %v", err)
				}
			}
		})
	}
}

// Accepted creations and submissions cannot lose their session identity. A
// rejected creation legitimately has none, which its real-daemon E2E covers.
func TestReceiptRejectsMissingTargetOutsideRejectedCreation(t *testing.T) {
	for _, test := range []struct{ kind, status string }{{"create", "accepted"}, {"user", "rejected"}} {
		t.Run(test.kind+"_"+test.status, func(t *testing.T) {
			field, body := "result", `{}`
			statusCode := 201
			if test.status == "rejected" {
				field, body = "error", `{"code":"invalid_submission","error":"rejected"}`
				statusCode = 400
			}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				_, _ = fmt.Fprintf(w, `{"operationId":"id","kind":%q,"target":"","status":%q,"httpStatus":%d,"deliveryStatus":null,"blockingReason":null,%q:%s}`, test.kind, test.status, statusCode, field, body)
			}))
			defer server.Close()
			conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "token"}, nil)
			if _, err := GetOperation(t.Context(), conn, "id"); err == nil {
				t.Fatal("receipt without required session identity accepted")
			} else if _, ok := errors.AsType[*ProtocolError](err); !ok {
				t.Fatalf("lost protocol classification: %v", err)
			}
		})
	}
}

func TestDomainReadsPreserveDecodedValues(t *testing.T) {
	connection := func(body string, status int) (*Connection, *httptest.Server) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/health" {
				_, _ = fmt.Fprint(w, `{"ok":true,"version":2,"capabilities":["session_context","settings_api"]}`)
				return
			}
			w.WriteHeader(status)
			_, _ = fmt.Fprint(w, body)
		}))
		t.Cleanup(server.Close)
		return NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "token"}, nil), server
	}

	t.Run("context snapshot", func(t *testing.T) {
		conn, _ := connection(`{"state":"ready","model":"model","provider":"provider","protocol":"responses","captured_at":123,"context_window_tokens":4096,"sections":[{"id":"history","label":"History","kind":"history","source":"transcript","preview":"hello","item_count":2,"byte_count":10,"pages":1}],"compaction":{"status":"compacted","strategy":"summary","before_items":4,"after_items":2}}`, http.StatusOK)
		got, err := GetContextSnapshot(t.Context(), conn, "s")
		if err != nil || got.State != "ready" || got.Model != "model" || got.Provider != "provider" || got.Protocol != "responses" || got.CapturedAt == nil || *got.CapturedAt != 123 || got.ContextWindowTokens == nil || *got.ContextWindowTokens != 4096 || len(got.Sections) != 1 {
			t.Fatalf("context values lost: %+v, %v", got, err)
		}
		section := got.Sections[0]
		if section != (ContextSection{ID: "history", Label: "History", Kind: "history", Source: "transcript", Preview: "hello", ItemCount: 2, ByteCount: 10, Pages: 1}) || got.Compaction.Status != "compacted" || got.Compaction.Strategy != "summary" || got.Compaction.BeforeItems == nil || *got.Compaction.BeforeItems != 4 || got.Compaction.AfterItems == nil || *got.Compaction.AfterItems != 2 {
			t.Fatalf("context section or compaction values lost: %+v", got)
		}
	})
	t.Run("context page", func(t *testing.T) {
		conn, _ := connection(`{"section":"history","content":"message","omitted":"older","page":2,"pages":3}`, http.StatusOK)
		got, err := GetContextPage(t.Context(), conn, "s", "history", 2)
		if err != nil || got != (ContextPage{Section: "history", Content: "message", Omitted: "older", Page: 2, Pages: 3}) {
			t.Fatalf("context page values lost: %+v, %v", got, err)
		}
	})
	t.Run("catalog", func(t *testing.T) {
		conn, _ := connection(`{"workspace":"/work","revision":"r","extensions":{"ext":false},"diagnostics":["warning"],"candidates":[{"id":"ext","kind":"extension","title":"Extension","source":"local","valid":true,"effective_enabled":false,"eligible":true,"description":"description","resolved_source":"/work/ext","preference_key":"ext","diagnostic":null,"shadowed_by":null,"global_preference":false,"session_override":true}]}`, http.StatusOK)
		got, err := GetCapabilityCatalog(t.Context(), conn, "s")
		if err != nil || got.Workspace != "/work" || got.Revision != "r" || len(got.Extensions) != 1 || got.Extensions["ext"] || len(got.Diagnostics) != 1 || got.Diagnostics[0] != "warning" || len(got.Candidates) != 1 {
			t.Fatalf("catalog values lost: %+v, %v", got, err)
		}
		candidate := got.Candidates[0]
		if candidate.ID != "ext" || candidate.Kind != "extension" || candidate.Title != "Extension" || candidate.Source != "local" || !candidate.Valid || candidate.EffectiveEnabled || !candidate.Eligible || candidate.Description == nil || *candidate.Description != "description" || candidate.ResolvedSource == nil || *candidate.ResolvedSource != "/work/ext" || candidate.PreferenceKey == nil || *candidate.PreferenceKey != "ext" || candidate.Diagnostic != nil || candidate.ShadowedBy != nil || candidate.GlobalPreference == nil || *candidate.GlobalPreference || candidate.SessionOverride == nil || !*candidate.SessionOverride {
			t.Fatalf("candidate values lost: %+v", candidate)
		}
	})
	t.Run("settings", func(t *testing.T) {
		conn, _ := connection(`{"profiles":{"active":"local","providers":{"local":{"model":"m","protocol":"responses","baseUrl":"http://local","extension":"ext","hasKey":false}}},"mcp":{},"capabilities":{},"ui":{"opens":{"s":2},"pinned":["s"],"archived":[],"thinking":false,"tools":true},"credentials":{"providers":["local"],"mcp":{"tools":{"bearerToken":false,"headers":["Authorization"],"env":["TOKEN"]}}}}`, http.StatusOK)
		got, err := GetSettings(t.Context(), conn)
		profile := got.Profiles.Providers["local"]
		names := got.Credentials.MCP["tools"]
		if err != nil || got.Profiles.Active != "local" || profile.Model != "m" || profile.Protocol != "responses" || profile.BaseURL != "http://local" || profile.Extension != "ext" || profile.HasKey || got.MCP == nil || got.UI.Opens["s"] != 2 || len(got.UI.Pinned) != 1 || got.UI.Pinned[0] != "s" || got.UI.Thinking || !got.UI.Tools || len(got.Credentials.Providers) != 1 || got.Credentials.Providers[0] != "local" || names.BearerToken || len(names.Headers) != 1 || names.Headers[0] != "Authorization" || len(names.Env) != 1 || names.Env[0] != "TOKEN" {
			t.Fatalf("settings values lost: %+v, %v", got, err)
		}
	})
}

func TestCommandReadsPreserveArgumentsAndPageActions(t *testing.T) {
	body := `[{"name":"/choose","description":"Choose","method":"choose","modelCallable":false,"userTurn":true,"skill":true,"page":true,"arguments":[{"name":"choice","description":"Pick one","required":false,"choices":["first","second"]}]}]`
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			_, _ = fmt.Fprint(w, `{"ok":true,"version":2,"capabilities":["session_commands"]}`)
			return
		}
		_, _ = fmt.Fprint(w, body)
	}))
	t.Cleanup(server.Close)
	conn := NewConnection(ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "token"}, nil)
	commands, err := ListSessionCommands(t.Context(), conn, "s")
	if err != nil || len(commands) != 1 {
		t.Fatalf("command catalog lost: %+v, %v", commands, err)
	}
	cmd := commands[0]
	if cmd.Name != "/choose" || cmd.Description != "Choose" || cmd.Method != "choose" || cmd.ModelCallable || !cmd.UserTurn || !cmd.Skill || cmd.Page == nil || !*cmd.Page || len(cmd.Arguments) != 1 {
		t.Fatalf("command fields lost: %+v", cmd)
	}
	arg := cmd.Arguments[0]
	if arg.Name != "choice" || arg.Description != "Pick one" || arg.Required || len(arg.Choices) != 2 || arg.Choices[0] != "first" || arg.Choices[1] != "second" {
		t.Fatalf("command arguments lost: %+v", arg)
	}
	body = `{"result":{"page":{"title":"Tools","summary":"Summary","empty":"No tools","rows":[{"id":"tool","text":"Tool","badge":"On","tone":"active","detail":"Description"}],"actions":[{"key":"x","label":"Choose","run":"choose","input":"choice","options":["first","second"],"row":false,"confirm":true}],"glance":{"title":"Glance","rows":[{"id":"tool","text":"Tool","badge":"","tone":"plain","detail":""}]}}}}`
	page, err := LoadPage(t.Context(), conn, "s", "/tools")
	if err != nil || page == nil || page.Title != "Tools" || page.Summary != "Summary" || page.Empty != "No tools" || len(page.Rows) != 1 || len(page.Actions) != 1 || page.Glance == nil || page.Glance.Title != "Glance" || len(page.Glance.Rows) != 1 {
		t.Fatalf("page values lost: %+v, %v", page, err)
	}
	if page.Rows[0] != (PageRow{ID: "tool", Text: "Tool", Badge: "On", Tone: ToneActive, Detail: "Description"}) || page.Glance.Rows[0] != (PageRow{ID: "tool", Text: "Tool", Tone: TonePlain}) {
		t.Fatalf("page row values lost: %+v", page)
	}
	action := page.Actions[0]
	if action.Key != "x" || action.Label != "Choose" || action.Run != "choose" || action.Input != "choice" || action.Row || !action.Confirm || len(action.Options) != 2 || action.Options[0] != "first" || action.Options[1] != "second" {
		t.Fatalf("page action values lost: %+v", action)
	}
}
