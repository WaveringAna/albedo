//go:build unix

// The independent adapter must carry the real daemon's responses into the TUI
// without owning its launcher, workspace discovery, or wire-format decoding.
package e2e

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui"

	tea "charm.land/bubbletea/v2"
)

func TestIndependentAdapterDrivesContextTreeAndSessionCatalog(t *testing.T) {
	profile := providerRoute(t, echoReply)
	before := conn(t).Snapshot()
	attached, err := daemon.Attach(t.Context(), before, nil)
	if err != nil {
		t.Fatal(err)
	}
	workspace := t.TempDir()
	skill := filepath.Join(workspace, ".agents", "skills", "adapter-review", "SKILL.md")
	if err := os.MkdirAll(filepath.Dir(skill), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(skill, []byte("---\nname: adapter-review\ndescription: Review an attached adapter workflow\n---\nInspect the prepared request.\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	session, err := daemon.CreateSession(t.Context(), attached, daemon.CreateSessionRequest{Workspace: workspace, Provider: profile})
	if err != nil {
		t.Fatal(err)
	}
	client := daemon.NewChatClient(attached, session.ID)
	for index, prompt := range []string{"adapter durable first turn", "inspect adapter durable history"} {
		if _, err := client.Send(t.Context(), prompt, nil); err != nil {
			t.Fatal(err)
		}
		waitIdle(t, session.ID, profile, index+1)
	}
	preview, err := daemon.GetSessionPreview(t.Context(), attached, session.ID, 20)
	if err != nil {
		t.Fatal(err)
	}
	foundPreview := false
	for _, item := range preview.Items {
		foundPreview = foundPreview || strings.Contains(item.Preview, "inspect adapter durable history")
	}
	if !foundPreview {
		t.Fatalf("preview omitted the completed turn: %+v", preview)
	}
	commands, err := daemon.ListSessionCommands(t.Context(), attached, session.ID)
	if err != nil {
		t.Fatal(err)
	}
	commandIndex := slices.IndexFunc(commands, func(command daemon.SessionCommand) bool {
		return command.Name == "/adapter-review"
	})
	if commandIndex < 0 {
		t.Fatal("enabled workspace skill is missing from the command menu catalog")
	}
	skillCommand := commands[commandIndex]
	if !skillCommand.Skill || !skillCommand.UserTurn || skillCommand.Method == "" || skillCommand.Description != "Review an attached adapter workflow" || len(skillCommand.Arguments) != 1 {
		t.Fatalf("skill command lost its runnable metadata: %+v", skillCommand)
	}
	driver := driveTUIWithConnection(t, &session, attached)
	defer driver.App.Chat.Close()
	driver.Dispatch(tui.ChatOpenContextInspectorMsg{})
	inspector := &driver.App.ContextInspector
	if inspector.Error != "" || inspector.Snapshot == nil || inspector.Snapshot.State != "ready" {
		t.Fatalf("prepared context did not reach inspector: %+v", inspector)
	}
	history := -1
	for index, section := range inspector.Snapshot.Sections {
		if section.Kind == "history" && section.Pages > 0 {
			history = index
			break
		}
	}
	if history < 0 {
		t.Fatal("prepared context has no readable history section")
	}
	inspector.Cursor = history
	driver.Dispatch(tea.KeyPressMsg{Code: tea.KeyEnter})
	if inspector.Detail == nil || inspector.Detail.Value == nil || !strings.Contains(inspector.Detail.Value.Content, "adapter durable first turn") {
		t.Fatalf("context detail lost prior history: %+v", inspector.Detail)
	}
	driver.Dispatch(tui.ContextDoneMsg{})
	driver.Dispatch(tui.ChatOpenTreePickerMsg{})
	if driver.App.TreePicker.Error != "" || len(driver.App.TreePicker.Checkpoints) < 2 {
		t.Fatalf("completed turns did not reach checkpoint picker: %+v", driver.App.TreePicker)
	}
	driver.Dispatch(tui.TreeCancelMsg{})
	driver.Dispatch(tui.ChatOpenCapabilityPageMsg{Kind: "skills"})
	page := &driver.App.CapabilityPage
	selected := -1
	for index, item := range page.Items {
		if item.Candidate.Source == skill {
			selected = index
			break
		}
	}
	if page.Error != "" || selected < 0 || !page.Items[selected].Candidate.EffectiveEnabled {
		t.Fatalf("workspace skill did not reach catalog page: %+v", page)
	}
	page.Cursor = selected
	driver.Dispatch(tea.KeyPressMsg{Code: 's', Text: "s"})
	// The app also refreshes its command menu after this save, which starts
	// recurring glance polls. Drive through the page's actual save and reload
	// completion instead of asking the synchronous driver to settle timers.
	queued := driver.results(driver.Update(tea.KeyPressMsg{Code: tea.KeySpace}))
	for step := 0; page.Saving || page.Loading; step++ {
		if step == 16 || len(queued) == 0 {
			t.Fatalf("catalog save did not finish: %+v", page)
		}
		message := queued[0]
		queued = queued[1:]
		command := driver.Update(message)
		if page.Saving || page.Loading {
			queued = append(queued, driver.results(command)...)
		}
	}
	catalog, err := daemon.GetCapabilityCatalog(t.Context(), attached, session.ID)
	if err != nil {
		t.Fatal(err)
	}
	disabled := false
	for _, candidate := range catalog.Candidates {
		if candidate.Source == skill {
			disabled = !candidate.EffectiveEnabled && candidate.SessionOverride != nil && !*candidate.SessionOverride
		}
	}
	if page.Error != "" || !disabled {
		t.Fatalf("session catalog toggle was not persisted: %+v", page)
	}
	commands, err = daemon.ListSessionCommands(t.Context(), attached, session.ID)
	if err != nil {
		t.Fatal(err)
	}
	if slices.ContainsFunc(commands, func(command daemon.SessionCommand) bool {
		return command.Name == "/adapter-review"
	}) {
		t.Fatal("disabled skill still appears as a runnable command")
	}
	after, err := readDaemonSnapshot(suite.home)
	if err != nil || after != before {
		t.Fatalf("independent attachment replaced its daemon: before=%+v after=%+v err=%v", before, after, err)
	}
}

func TestTypedMCPSecretsKeepReplaceRemoveAndClear(t *testing.T) {
	profile := providerRoute(t, echoReply)
	attached, err := daemon.Attach(t.Context(), conn(t).Snapshot(), nil)
	if err != nil {
		t.Fatal(err)
	}
	session, err := daemon.CreateSession(t.Context(), attached, daemon.CreateSessionRequest{Workspace: t.TempDir(), Provider: profile})
	if err != nil {
		t.Fatal(err)
	}
	name := "typed-secret-patch"
	server := config.MCPServer{Type: "http", URL: "http://127.0.0.1:1/mcp", Enabled: new(false)}
	t.Cleanup(func() {
		if _, err := daemon.SaveMCP(context.Background(), attached, session.ID, daemon.MCPUpdateRequest{Name: name, Server: nil, Secrets: daemon.MCPSecretsPatch{}}); err != nil {
			t.Error(err)
		}
	})
	save := func(patch daemon.MCPSecretsPatch) daemon.Settings {
		t.Helper()
		if _, err := daemon.SaveMCP(t.Context(), attached, session.ID, daemon.MCPUpdateRequest{Name: name, Server: &server, Secrets: patch}); err != nil {
			t.Fatal(err)
		}
		settings, err := daemon.GetSettings(t.Context(), attached)
		if err != nil {
			t.Fatal(err)
		}
		return settings
	}
	save(daemon.MCPSecretsPatch{
		BearerToken: new("initial-bearer"),
		Headers:     map[string]*string{"x-retained": new("initial-header"), "x-removed": new("remove-header")},
		Env:         map[string]*string{"RETAINED": new("initial-env"), "REMOVED": new("remove-env")},
	})
	kept := save(daemon.MCPSecretsPatch{}).Credentials.MCP[name]
	if !kept.BearerToken || !slices.Equal(kept.Headers, []string{"x-removed", "x-retained"}) || !slices.Equal(kept.Env, []string{"REMOVED", "RETAINED"}) {
		t.Fatalf("omitted secret patch changed saved names: %+v", kept)
	}
	replaced := save(daemon.MCPSecretsPatch{
		BearerToken: new("replacement-bearer"),
		Headers:     map[string]*string{"x-retained": new("replacement-header"), "x-removed": nil},
		Env:         map[string]*string{"RETAINED": new("replacement-env"), "REMOVED": nil},
	}).Credentials.MCP[name]
	if !replaced.BearerToken || !slices.Equal(replaced.Headers, []string{"x-retained"}) || !slices.Equal(replaced.Env, []string{"RETAINED"}) {
		t.Fatalf("named removal changed retained secret names: %+v", replaced)
	}
	// The fixture already owns this daemon home. Reading its stored test values
	// distinguishes replacement from accidental omission without exposing them
	// through the adapter's redacted settings response.
	data, err := os.ReadFile(filepath.Join(suite.home, "creds.json"))
	if err != nil {
		t.Fatal(err)
	}
	var stored struct {
		MCP map[string]struct {
			BearerToken string            `json:"bearerToken"`
			Headers     map[string]string `json:"headers"`
			Env         map[string]string `json:"env"`
		} `json:"mcp"`
	}
	if err := json.Unmarshal(data, &stored); err != nil {
		t.Fatal(err)
	}
	values := stored.MCP[name]
	if values.BearerToken != "replacement-bearer" || values.Headers["x-retained"] != "replacement-header" || values.Env["RETAINED"] != "replacement-env" {
		t.Fatal("typed replacement patch did not update persisted test secrets")
	}
	cleared := save(daemon.MCPSecretsPatch{RemoveBearerToken: true, ClearHeaders: true, ClearEnv: true}).Credentials.MCP[name]
	if cleared.Any() {
		t.Fatalf("explicit container removal retained secret names: %+v", cleared)
	}
}

func TestAttachedWebhookScreenCreatesConfiguresDisablesAndDeletesHook(t *testing.T) {
	profile := providerRoute(t, echoReply)
	attached, err := daemon.Attach(t.Context(), conn(t).Snapshot(), nil)
	if err != nil {
		t.Fatal(err)
	}
	session, err := daemon.CreateSession(t.Context(), attached, daemon.CreateSessionRequest{Workspace: t.TempDir(), Provider: profile})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := daemon.SelectExtension(t.Context(), attached, session.ID, daemon.ExtensionSelectionRequest{Name: "webhooks", Scope: "session", Enabled: new(true)}); err != nil {
		t.Fatal(err)
	}
	driver := driveTUIWithConnection(t, &session, attached)
	defer driver.App.Chat.Close()
	driver.Dispatch(tui.ChatOpenWebhooksPageMsg{})
	driver.Dispatch(tea.KeyPressMsg{Code: 'n', Text: "n"})
	if driver.App.WebhooksPage.Error != "" || driver.App.WebhooksPage.Form == nil {
		t.Fatalf("cannot open webhook creation form: %+v", driver.App.WebhooksPage)
	}
	driver.Type("attached-alert")
	driver.App.WebhooksPage.Form.Inputs["header"].SetValue("x-adapter-signature")
	driver.App.WebhooksPage.Form.Inputs["prefix"].SetValue("adapter=")
	driver.Dispatch(tea.KeyPressMsg{Code: 's', Mod: tea.ModCtrl})
	page := &driver.App.WebhooksPage
	if page.Error != "" || page.Reveal == nil || page.Reveal.Secret == "" {
		t.Fatalf("webhook form lost its generated signing secret: %+v", page)
	}
	listed, err := daemon.RunWebhook(t.Context(), attached, session.ID, daemon.WebhookRequest{Action: daemon.WebhookList})
	if err != nil {
		t.Fatal(err)
	}
	var hook *daemon.Webhook
	for _, entry := range listed.Hooks {
		if entry.Hook.Session == session.ID && entry.Hook.Name == "attached-alert" {
			copy := entry.Hook
			hook = &copy
		}
	}
	if hook == nil || hook.Header != "x-adapter-signature" || hook.Prefix != "adapter=" || !hook.Enabled {
		t.Fatalf("form did not persist its configured hook: %+v", hook)
	}
	deleted := false
	t.Cleanup(func() {
		if deleted {
			return
		}
		if _, err := daemon.RunWebhook(context.Background(), attached, session.ID, daemon.WebhookRequest{Action: daemon.WebhookDelete, HookID: hook.ID}); err != nil {
			t.Error(err)
		}
	})
	for _, request := range []daemon.WebhookRequest{
		{Action: daemon.WebhookSignature, HookID: hook.ID, Header: "x-typed-signature", Prefix: "typed="},
		{Action: daemon.WebhookDisable, HookID: hook.ID},
		{Action: daemon.WebhookEnable, HookID: hook.ID},
	} {
		updated, err := daemon.RunWebhook(t.Context(), attached, session.ID, request)
		if err != nil {
			t.Fatal(err)
		}
		if updated.Hook == nil || updated.Hook.ID != hook.ID || updated.Hook.Session != session.ID || updated.Hook.Revision != hook.Revision+1 || updated.Hook.Header != "x-typed-signature" || updated.Hook.Prefix != "typed=" || updated.Hook.Address == "" {
			t.Fatalf("typed %s result lost updated hook: %+v", request.Action, updated)
		}
		if updated.Hook.Enabled != (request.Action != daemon.WebhookDisable) {
			t.Fatalf("typed %s result lost enabled state: %+v", request.Action, updated.Hook)
		}
		hook = updated.Hook
		persisted, err := daemon.RunWebhook(t.Context(), attached, session.ID, daemon.WebhookRequest{Action: daemon.WebhookList})
		if err != nil {
			t.Fatal(err)
		}
		found := false
		for _, entry := range persisted.Hooks {
			if entry.Hook.ID == hook.ID {
				found = true
				if entry.Hook != *hook {
					t.Fatalf("typed %s result differs from persisted hook: result=%+v saved=%+v", request.Action, hook, entry.Hook)
				}
			}
		}
		if !found {
			t.Fatalf("typed %s hook missing from list", request.Action)
		}
	}
	driver.Dispatch(tea.KeyPressMsg{Code: tea.KeyEnter})
	selected := -1
	for index, item := range page.Hooks {
		if item.ID == hook.ID {
			selected = index
		}
	}
	if selected < 0 {
		t.Fatal("created hook did not appear after secret dismissal")
	}
	page.Cursor = selected
	driver.Dispatch(tea.KeyPressMsg{Code: tea.KeySpace})
	driver.Dispatch(tea.KeyPressMsg{Code: 'r', Text: "r"})
	listed, err = daemon.RunWebhook(t.Context(), attached, session.ID, daemon.WebhookRequest{Action: daemon.WebhookList})
	if err != nil {
		t.Fatal(err)
	}
	disabled := false
	for _, entry := range listed.Hooks {
		if entry.Hook.ID == hook.ID {
			disabled = !entry.Hook.Enabled
		}
	}
	if page.Error != "" || !disabled {
		t.Fatalf("disabled hook did not survive reload: %+v", page)
	}
	// Deletion returns the last saved hook, then authoritative reload removes it.
	for _, entry := range listed.Hooks {
		if entry.Hook.ID == hook.ID {
			hook = &entry.Hook
		}
	}
	removed, err := daemon.RunWebhook(t.Context(), attached, session.ID, daemon.WebhookRequest{Action: daemon.WebhookDelete, HookID: hook.ID})
	if err != nil {
		t.Fatal(err)
	}
	if removed.Hook == nil || *removed.Hook != *hook {
		t.Fatalf("typed deletion lost deleted hook: result=%+v saved=%+v", removed, hook)
	}
	deleted = true
	driver.Dispatch(tea.KeyPressMsg{Code: 'r', Text: "r"})
	listed, err = daemon.RunWebhook(t.Context(), attached, session.ID, daemon.WebhookRequest{Action: daemon.WebhookList})
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range listed.Hooks {
		if entry.Hook.ID == hook.ID {
			t.Fatal("deleted hook still appears in authoritative list")
		}
	}
	if page.Error != "" {
		t.Fatal(page.Error)
	}
}
