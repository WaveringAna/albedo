import albedo/harness/client_api
import albedo/harness/extension as harness_extension
import albedo/harness/extensions/paperclips/command as paperclips_command
import albedo/harness/extensions/paperclips/ledger as paperclips
import albedo/harness/extensions/paperclips/migrations/reply
import albedo/harness/extensions/paperclips/migrations/resolution
import albedo/harness/extensions/paperclips/migrations/revision
import albedo/harness/extensions/paperclips/migrations/scope
import albedo/harness/extensions/paperclips/migrations/title
import albedo/harness/extensions/paperclips/rpc
import gleam/http
import gleam/json
import gleam/option.{Some}

import albedo/harness/extensions/paperclips/service

pub fn extension() -> harness_extension.Extension {
  harness_extension.Extension(
    "paperclips",
    "A vent channel: the model records friction, the user reviews it in /paperclips.",
    ["python"],
    [
      harness_extension.ClientPlugin([
        client_api.Command(
          "/paperclips",
          client_api.Read,
          [],
          client_api.Operation(
            "listPaperclips",
            http.Get,
            "/extensions/paperclips/items",
            [],
            [],
            [],
            [],
            json.object([]),
            Some(200),
          ),
        ),
      ]),
      harness_extension.GlancePlugin(service.sidebar, service.resource_url),
      harness_extension.ServicePlugin(harness_extension.Service(
        fn(_, _) {
          harness_extension.Admission(harness_extension.DaemonToken, 65_536)
        },
        service.handle,
      )),
      harness_extension.MigrationPlugin(harness_extension.SchemaMigration(
        title.apply,
      )),
      harness_extension.MigrationPlugin(harness_extension.SchemaMigration(
        scope.apply,
      )),
      harness_extension.MigrationPlugin(harness_extension.SchemaMigration(
        reply.apply,
      )),
      harness_extension.MigrationPlugin(harness_extension.SchemaMigration(
        resolution.apply,
      )),
      harness_extension.MigrationPlugin(harness_extension.SchemaMigration(
        revision.apply,
      )),
      harness_extension.ToolPlugin(vent_instructions, [], ["paperclips"], []),
      // The prepared workspace records where a new vent was filed; the
      // ledger itself is global, so /paperclips needs no workspace.
      harness_extension.ManagedPlugin(fn(store, _, workspace) {
        Ok(
          harness_extension.Managed(
            ..harness_extension.empty(),
            routes: [
              #("paperclips", fn(store, session, request) {
                rpc.handle(store, workspace, session, request)
              }),
            ],
            commands: [paperclips_command.command(store)],
          ),
        )
      }),
    ],
    paperclips.initialise,
  )
}

const vent_instructions = "You have a vent channel the user reviews instead of receiving as interruptions. When the harness, a workflow, a bug, or the user's own habits cost you real work, say so once where it can be triaged: await vent(topic, message, suggestion=\"\", title=\"\") files one, with topic one of harness, workflow, bug, user, or other; the optional title is the short line the /paperclips list shows, so make it a few specific words and put the rest in message. Keep it specific and actionable: what happened, what it cost you, and what would fix it; a user vent is reviewable workflow feedback, never an insult. The user reviews vents with /paperclips and can answer them; the answer reaches you as a note and is stored on the vent as its reply. Check await vents(limit=20) before recording so you do not file the same complaint twice; vents from every session share one ledger. When a change you made fixes what an open or acknowledged vent describes, yours or another session's, await resolve_vent(id, note) closes it, with note saying what fixed it (the commit or change); the user sees the note on the vent. Resolve only what your change actually fixed; everything else stays the user's to triage. Venting is never a substitute for telling the user something urgent in your reply."
