import albedo/harness/extension as harness_extension
import albedo/harness/extensions/paperclips/command as paperclips_command
import albedo/harness/extensions/paperclips/ledger as paperclips
import albedo/harness/extensions/paperclips/rpc

pub fn extension() -> harness_extension.Extension {
  harness_extension.Extension(
    "paperclips",
    "A vent channel: the model records friction, the user reviews it in /paperclips.",
    ["python"],
    [
      harness_extension.ToolPlugin(vent_instructions, [], ["paperclips"], []),
      // The prepared workspace scopes both the Python route and /paperclips.
      harness_extension.ManagedPlugin(fn(store, _, workspace) {
        Ok(
          harness_extension.Managed(
            ..harness_extension.empty(),
            routes: [
              #("paperclips", fn(store, session, request) {
                rpc.handle(store, workspace, session, request)
              }),
            ],
            commands: [paperclips_command.command(store, workspace)],
          ),
        )
      }),
    ],
    paperclips.initialise,
  )
}

const vent_instructions = "You have a vent channel the user reviews instead of receiving as interruptions. When the harness, a workflow, a bug, or the user's own habits cost you real work, say so once where it can be triaged: await vent(topic, message, suggestion=\"\", title=\"\") files one, with topic one of harness, workflow, bug, user, or other; the optional title is the short line the /paperclips list shows, so make it a few specific words and put the rest in message. Keep it specific and actionable: what happened, what it cost you, and what would fix it; a user vent is reviewable workflow feedback, never an insult. The user reviews vents with /paperclips and can answer them, and the answer reaches you as a note. Check await vents(limit=20) before recording so you do not file the same complaint twice. Venting is never a substitute for telling the user something urgent in your reply."
