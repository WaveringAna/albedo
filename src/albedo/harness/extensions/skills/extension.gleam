//// Progressive Agent Skills extension.
////
//// Each opened runtime session gets one immutable metadata snapshot. That same
//// snapshot drives prompt context, Python RPC, session commands, and user slash
//// activation: every cataloged skill contributes its slash command to the
//// unified command catalog, where a user invocation submits the activation as
//// one turn and a model invocation returns it as data.

import albedo/harness/capabilities
import albedo/harness/command
import albedo/harness/extension as harness_extension
import albedo/harness/extensions/skills/catalog
import albedo/harness/extensions/skills/rpc
import albedo/harness/settings
import gleam/dict
import gleam/list
import gleam/result

pub fn extension() -> harness_extension.Extension {
  extension_at(catalog.native_home())
}

/// Explicit home keeps integration tests and embedders isolated.
pub fn extension_at(home: String) -> harness_extension.Extension {
  harness_extension.Extension(
    "skills",
    "Discover Agent Skills metadata and activate selected instructions or resources on demand.",
    ["python", "commands"],
    [
      harness_extension.ManagedPlugin(fn(_, session, workspace) {
        use discovered <- result.try(catalog.scan_at(workspace, home))
        use names <- result.try(
          list.try_fold(discovered.skills, [], fn(acc, skill) {
            use enabled <- result.try(capabilities.enabled(
              settings.home(),
              session,
              "skills",
              skill.name,
            ))
            Ok(case enabled {
              True -> [skill.name, ..acc]
              False -> acc
            })
          }),
        )
        let snapshot = catalog.only(discovered, names)
        Ok(
          harness_extension.Managed(
            ..harness_extension.empty(),
            context: catalog.context(snapshot),
            instructions: instructions,
            python_modules: ["skills"],
            routes: [
              #("skills", fn(_, _, request) { rpc.handle(snapshot, request) }),
            ],
            commands: list.map(catalog.commands(snapshot), skill_command(
              snapshot,
              _,
            )),
          ),
        )
      }),
    ],
    harness_extension.no_initialise,
  )
}

const instructions = "Agent Skills are cataloged session commands. Invoke one through the `commands` object (commands.catalog() maps slash names to methods): it returns the skill's instructions as data and never submits a turn or executes bundled scripts. `await skills.resources(name)` returns a record whose .resources lists bundled resource names, and `await skills.read(name, resource=\"SKILL.md\", offset=0, limit=16384)` reads one bounded page as a record: page.content, page.next_offset, and page.truncated (page[\"content\"] works too). Failures raise SkillsError. A user may explicitly run the listed slash command, which submits the activation as one user turn."

/// One cataloged skill as a session command: both callers resolve the same
/// activation, and only the delivery differs.
fn skill_command(
  snapshot: catalog.Catalog,
  entry: catalog.Command,
) -> command.Command {
  command.Command(
    entry.command,
    entry.description,
    [command.Argument("arguments", "arguments for the skill", False, [])],
    True,
    True,
    False,
    fn(_context, caller, args) {
      let arguments = dict.get(args, "arguments") |> result.unwrap("")
      use activation <- result.try(catalog.activate(
        snapshot,
        entry.name,
        arguments,
      ))
      case caller {
        command.UserCall ->
          Ok(command.Turn(
            entry.command
              <> case arguments {
              "" -> ""
              value -> " " <> value
            },
            catalog.activation_prompt(activation),
          ))
        command.ModelCall -> Ok(command.Data(rpc.activation_json(activation)))
      }
    },
  )
}

/// Compatibility helpers for embedders and direct tests. Runtime sessions use the
/// immutable snapshot prepared above rather than calling these again.
pub fn discover_at(workspace: String, home: String) {
  catalog.scan_at(workspace, home)
  |> result.map(fn(snapshot) { #(snapshot.skills, snapshot.diagnostics) })
}

pub fn catalog_at(workspace: String, home: String) {
  catalog.scan_at(workspace, home) |> result.map(catalog.context)
}
