//// `/link`: tie this workspace to others that hold the same project, such as
//// one repository checked out on two hosts. Linked workspaces read each
//// other's memory and work items; each keeps writing its own, so a member
//// whose folder is gone loses nothing and unlinking undoes nothing.

import albedo/harness/client_api
import gleam/http

import albedo/harness/command.{Argument}
import albedo/harness/extension
import albedo/harness/extensions/links/ledger
import albedo/harness/extensions/links/presence.{type Presence, Gone}
import albedo/harness/extensions/links/service
import albedo/harness/links
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string

pub fn extension() -> extension.Extension {
  extension.Extension(
    "links",
    "Workspaces linked into one project share memory and work items.",
    [],
    [
      extension.CommandPlugin([
        command.resource(
          "/link",
          "Show the workspaces linked with this one, or change them: add <workspace>, remove <workspace>. Linked workspaces share memory and work items; each keeps its own, so removing one loses nothing.",
          [
            Argument("action", "what to change; omit to list the links", False, [
              "add", "remove",
            ]),
            Argument(
              "details",
              "add: <path or host:/path> · remove: <workspace as listed>",
              False,
              [],
            ),
          ],
        ),
      ]),
      extension.ClientPlugin([
        client_api.Command(
          "/link",
          client_api.Read,
          [],
          client_api.Operation(
            "listLinks",
            http.Get,
            "/extensions/links/groups",
            [],
            [#("workspace", client_api.Session("/workspace"))],
            [],
            [],
            json.object([]),
            Some(200),
          ),
        ),
      ]),
      extension.ServicePlugin(extension.Service(
        fn(_, _) { extension.Admission(extension.DaemonToken, 65_536) },
        service.handle,
      )),
      extension.ManagedPlugin(fn(storage, _, workspace) {
        Ok(
          extension.Managed(
            ..extension.empty(),
            context: context(links.group(storage, workspace)),
          ),
        )
      }),
    ],
    ledger.initialise,
  )
}

/// What the model is told about the group it works in; nothing alone. A
/// session opening must not wait on a host, so only a recent probe tells
/// whether a remote member's folder is gone.
fn context(group: List(String)) -> String {
  case group {
    [_] | [] -> ""
    [_, ..linked] ->
      "This workspace is linked with "
      <> string.join(
        list.map2(linked, presence.presences(linked, 0), describe),
        ", ",
      )
      <> ": the same project in other places. memory and the work ledger "
      <> "read across all of them, and what you write is filed in this "
      <> "workspace. A work item says where it was filed (its workspace field)."
  }
}

fn describe(member: String, presence: Presence) -> String {
  case presence {
    Gone -> member <> " (its folder is gone)"
    _ -> member
  }
}
