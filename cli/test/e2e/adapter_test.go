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
	t.Parallel()
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
	pending, err := daemon.GetContextSnapshot(t.Context(), attached, session.ID)
	if err != nil {
		t.Fatalf("read context before its first turn: %v", err)
	}
	if pending.State != "pending" || strings.TrimSpace(pending.Reason) == "" {
		t.Fatalf("pending context lost its readable reason: %+v", pending)
	}
	if pending.SnapshotID != "" || pending.CapturedAt != nil || len(pending.Sections) != 0 {
		t.Fatalf("reading pending context prepared a snapshot: %+v", pending)
	}
	if requests := suite.provider.requests(profile); len(requests) != 0 {
		t.Fatalf("reading pending context called the provider: %d requests", len(requests))
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
	if skillCommand.Delivery != "input" || skillCommand.CommandID != "/adapter-review" || !skillCommand.UserTurn || skillCommand.Method != "PUT" || skillCommand.Description != "Review an attached adapter workflow" || len(skillCommand.Arguments) != 1 {
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
	driver.Dispatch(tea.KeyPressMsg{Code: tea.KeyEnter, Mod: tea.ModShift})
	// The app also refreshes its command menu after this save, which starts
	// recurring glance polls. Drive through the page's actual save and reload
	// completion instead of asking the synchronous driver to settle timers.
	queued := driver.results(driver.Update(tea.KeyPressMsg{Code: tea.KeyEnter}))
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
	if !slices.ContainsFunc(commands, func(command daemon.SessionCommand) bool { return command.Name == "/adapter-review" }) {
		t.Fatal("desired skill selection prematurely replaced the loaded command catalogue")
	}
	if result, err := daemon.ReloadSession(t.Context(), attached, session.ID, daemon.ReloadRequest{Target: "session"}); err != nil || result.Session == nil || result.Session.Failure != nil {
		t.Fatalf("reload disabled skill: %+v %v", result, err)
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
	if err != nil || after.Port != before.Port || after.Pid != before.Pid || after.Token != before.Token || after.Version != before.Version || after.Build != before.Build {
		t.Fatalf("independent attachment replaced its daemon: before=%+v after=%+v err=%v", before, after, err)
	}
}

func TestTUICapabilityPageEnablesAndLoadsSkillCommands(t *testing.T) {
	providerRoute(t, echoReply)
	t.Parallel()
	workspace := t.TempDir()
	skill := filepath.Join(workspace, ".agents", "skills", "enable-review", "SKILL.md")
	if err := os.MkdirAll(filepath.Dir(skill), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(skill, []byte("---\nname: enable-review\ndescription: Verify enabling the skills extension\n---\nReview the current task.\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	session := daemonSession(t, newSession(t, workspace))
	if _, err := daemon.SelectExtension(t.Context(), conn(t), session.ID, daemon.ExtensionSelectionRequest{Name: "skills", Scope: "session", ETag: session.ETag, Enabled: new(false)}); err != nil {
		t.Fatal(err)
	}
	if reloaded, err := daemon.ReloadSession(t.Context(), conn(t), session.ID, daemon.ReloadRequest{Target: "session"}); err != nil || reloaded.Session == nil || reloaded.Session.State != "applied" {
		t.Fatalf("disable skills before opening its page: %+v, %v", reloaded, err)
	}
	commands, err := daemon.ListSessionCommands(t.Context(), conn(t), session.ID)
	if err != nil || slices.ContainsFunc(commands, func(command daemon.SessionCommand) bool { return command.Name == "/enable-review" }) {
		t.Fatalf("disabled skills retained runnable command: %+v, %v", commands, err)
	}
	session = daemonSession(t, session.ID)
	driver := driveTUI(t, &session)
	defer driver.App.Chat.Close()
	driver.Dispatch(tui.ChatOpenCapabilityPageMsg{Kind: "skills"})
	if driver.App.CapabilityPage.ExtensionEnabled {
		t.Fatal("page did not observe the disabled skills extension")
	}
	driver.Dispatch(tea.KeyPressMsg{Code: 't', Mod: tea.ModCtrl})
	if !driver.App.CapabilityPage.Confirming() {
		t.Fatal("ctrl+t did not request extension-enable confirmation")
	}
	driver.Dispatch(tea.KeyPressMsg{Code: tea.KeyEnter})
	if page := driver.App.CapabilityPage; page.Error != "" || !page.ExtensionEnabled || !strings.Contains(page.Notice, "Reload completed.") {
		t.Fatalf("confirmed extension enable did not reload:\n%s", driver.View())
	}
	commands, err = daemon.ListSessionCommands(t.Context(), conn(t), session.ID)
	if err != nil || !slices.ContainsFunc(commands, func(command daemon.SessionCommand) bool { return command.Name == "/enable-review" }) {
		t.Fatalf("enabled extension did not load the skill command: %+v, %v", commands, err)
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
	httpName, stdioName := "typed-secret-http", "typed-secret-stdio"
	servers := map[string]config.MCPServer{
		httpName:  {Type: "http", URL: "http://127.0.0.1:1/mcp", Enabled: new(false)},
		stdioName: {Type: "stdio", Command: "python3", Args: []string{}, Enabled: new(false)},
	}
	t.Cleanup(func() {
		for name := range servers {
			if _, err := updateMCP(context.Background(), attached, session.ID, daemon.MCPUpdateRequest{Name: name, Server: nil, Secrets: daemon.MCPSecretsPatch{}}); err != nil {
				t.Error(err)
			}
		}
	})
	save := func(name string, patch daemon.MCPSecretsPatch) daemon.Settings {
		t.Helper()
		server := servers[name]
		if _, err := updateMCP(t.Context(), attached, session.ID, daemon.MCPUpdateRequest{Name: name, Server: &server, Secrets: patch}); err != nil {
			t.Fatal(err)
		}
		settings, err := daemon.GetSettings(t.Context(), attached)
		if err != nil {
			t.Fatal(err)
		}
		return settings
	}
	save(httpName, daemon.MCPSecretsPatch{
		BearerToken: new("initial-bearer"),
		Headers:     map[string]*string{"x-retained": new("initial-header"), "x-removed": new("remove-header")},
	})
	save(stdioName, daemon.MCPSecretsPatch{Env: map[string]*string{"RETAINED": new("initial-env"), "REMOVED": new("remove-env")}})
	keptHTTP := save(httpName, daemon.MCPSecretsPatch{}).Credentials.MCP[httpName]
	keptStdio := save(stdioName, daemon.MCPSecretsPatch{}).Credentials.MCP[stdioName]
	if !keptHTTP.BearerToken || !slices.Equal(keptHTTP.Headers, []string{"x-removed", "x-retained"}) || !slices.Equal(keptStdio.Env, []string{"REMOVED", "RETAINED"}) {
		t.Fatalf("omitted secret patch changed saved names: HTTP=%+v stdio=%+v", keptHTTP, keptStdio)
	}
	replacedHTTP := save(httpName, daemon.MCPSecretsPatch{
		BearerToken: new("replacement-bearer"),
		Headers:     map[string]*string{"x-retained": new("replacement-header"), "x-removed": nil},
	}).Credentials.MCP[httpName]
	replacedStdio := save(stdioName, daemon.MCPSecretsPatch{Env: map[string]*string{"RETAINED": new("replacement-env"), "REMOVED": nil}}).Credentials.MCP[stdioName]
	if !replacedHTTP.BearerToken || !slices.Equal(replacedHTTP.Headers, []string{"x-retained"}) || !slices.Equal(replacedStdio.Env, []string{"RETAINED"}) {
		t.Fatalf("named removal changed retained secret names: HTTP=%+v stdio=%+v", replacedHTTP, replacedStdio)
	}
	// The fixture owns this home; inspect only its test values to distinguish
	// actual replacement from omission without public secret disclosure.
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
	if stored.MCP[httpName].BearerToken != "replacement-bearer" || stored.MCP[httpName].Headers["x-retained"] != "replacement-header" || stored.MCP[stdioName].Env["RETAINED"] != "replacement-env" {
		t.Fatal("typed replacement patch did not update persisted test secrets")
	}
	clearedHTTP := save(httpName, daemon.MCPSecretsPatch{RemoveBearerToken: true, ClearHeaders: true}).Credentials.MCP[httpName]
	clearedStdio := save(stdioName, daemon.MCPSecretsPatch{ClearEnv: true}).Credentials.MCP[stdioName]
	if clearedHTTP.Any() || clearedStdio.Any() {
		t.Fatalf("explicit container removal retained secret names: HTTP=%+v stdio=%+v", clearedHTTP, clearedStdio)
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
	enableExtension(t, attached, session.ID, "webhooks")
	driver := driveTUIWithConnection(t, &session, attached)
	defer driver.App.Chat.Close()
	driver.Dispatch(tui.ChatOpenWebhooksPageMsg{})
	driver.Dispatch(tea.KeyPressMsg{Code: 'o', Mod: tea.ModCtrl})
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
	listed, err := daemon.ListWebhooks(t.Context(), attached, session.ID)
	if err != nil {
		t.Fatal(err)
	}
	var hook *daemon.Webhook
	for _, entry := range listed {
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
		if _, err := daemon.DeleteWebhook(context.Background(), attached, hook.ID, hook.ETag); err != nil {
			t.Error(err)
		}
	})
	for _, patch := range []daemon.WebhookPatch{
		{SignatureHeader: new("x-typed-signature"), SignaturePrefix: new("typed=")},
		{Enabled: new(false)}, {Enabled: new(true)},
	} {
		updated, err := daemon.EditWebhook(t.Context(), attached, hook.ID, hook.ETag, patch)
		if err != nil {
			t.Fatal(err)
		}
		if updated.Hook == nil || updated.Hook.ID != hook.ID || updated.Hook.Session != session.ID || updated.Hook.Revision == hook.Revision || updated.Hook.Header != "x-typed-signature" || updated.Hook.Prefix != "typed=" {
			t.Fatalf("typed edit lost updated configuration: %+v", updated)
		}
		if patch.Enabled != nil && updated.Hook.Enabled != *patch.Enabled {
			t.Fatalf("typed edit lost enabled state: %+v", updated)
		}
		hook = updated.Hook
		persisted, err := daemon.ListWebhooks(t.Context(), attached, session.ID)
		if err != nil {
			t.Fatal(err)
		}
		found := false
		for _, entry := range persisted {
			if entry.Hook.ID != hook.ID {
				continue
			}
			found = true
			configuration := entry.Hook
			configuration.URL = ""
			configuration.Address = ""
			if configuration != *hook {
				t.Fatalf("saved configuration differs: result=%+v saved=%+v", hook, entry.Hook)
			}
			copy := entry.Hook
			hook = &copy
		}
		if !found {
			t.Fatal("edited hook missing from list")
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
	driver.Update(tea.WindowSizeMsg{Width: 70, Height: 20})
	for _, enabled := range []bool{true, false} {
		if view := driver.View(); !strings.Contains(view, "ctrl+t") || !strings.Contains(view, "agent access") {
			t.Fatalf("agent access is hidden on a narrow webhook page:\n%s", view)
		}
		driver.Dispatch(tea.KeyPressMsg{Code: 't', Mod: tea.ModCtrl})
		permission, permissionErr := daemon.GetWebhookPermission(t.Context(), attached, session.ID)
		if permissionErr != nil || permission.AgentManagement != enabled || driver.App.WebhooksPage.AgentManagement != enabled {
			t.Fatalf("agent access toggle did not persist %t: %+v, %v\n%s", enabled, permission, permissionErr, driver.View())
		}
		driver.Dispatch(tea.KeyPressMsg{Code: tea.KeyEscape})
		driver.Dispatch(tui.ChatOpenWebhooksPageMsg{})
		if driver.App.WebhooksPage.Error != "" || driver.App.WebhooksPage.AgentManagement != enabled {
			t.Fatalf("reopened page lost agent access %t:\n%s", enabled, driver.View())
		}
	}
	driver.Dispatch(tea.KeyPressMsg{Code: 'r', Mod: tea.ModCtrl})
	page.Cursor = selected
	driver.Dispatch(tea.KeyPressMsg{Code: tea.KeyEnter})
	driver.Dispatch(tea.KeyPressMsg{Code: 'r', Mod: tea.ModCtrl})
	listed, err = daemon.ListWebhooks(t.Context(), attached, session.ID)
	if err != nil {
		t.Fatal(err)
	}
	disabled := false
	for _, entry := range listed {
		if entry.Hook.ID == hook.ID {
			disabled = !entry.Hook.Enabled
		}
	}
	if page.Error != "" || !disabled {
		t.Fatalf("disabled hook did not survive reload: %+v", page)
	}
	// Deletion acknowledges its identity; authoritative reload removes it.
	for _, entry := range listed {
		if entry.Hook.ID == hook.ID {
			hook = &entry.Hook
		}
	}
	removed, err := daemon.DeleteWebhook(t.Context(), attached, hook.ID, hook.ETag)
	if err != nil {
		t.Fatal(err)
	}
	if removed.DeletedID != hook.ID {
		t.Fatalf("typed deletion lost deleted hook: result=%+v saved=%+v", removed, hook)
	}
	deleted = true
	driver.Dispatch(tea.KeyPressMsg{Code: 'r', Mod: tea.ModCtrl})
	listed, err = daemon.ListWebhooks(t.Context(), attached, session.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range listed {
		if entry.Hook.ID == hook.ID {
			t.Fatal("deleted hook still appears in authoritative list")
		}
	}
	if page.Error != "" {
		t.Fatal(page.Error)
	}
}
