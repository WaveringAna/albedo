//// `/link`: tie this workspace to others that hold the same project, such as
//// one repository checked out on two hosts. Linked workspaces read each
//// other's memory and work items; each keeps writing its own, so a member
//// whose folder is gone loses nothing and unlinking undoes nothing.

import albedo/harness/client_api
import gleam/http

import albedo/daemon/conversation
import albedo/daemon/store
import albedo/harness/command.{
  type Command, type StateOp, Argument, Command, Data, Note, UserCall,
}
import albedo/harness/extension
import albedo/harness/extensions/links/ledger
import albedo/harness/extensions/links/presence.{
  type Presence, Gone, Here, Unknown,
}
import albedo/harness/extensions/links/service
import albedo/harness/links
import albedo/harness/location
import albedo/harness/page
import albedo/harness/ssh
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

pub fn extension() -> extension.Extension {
  extension.Extension(
    "links",
    "Workspaces linked into one project share memory and work items.",
    [],
    [
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
            commands: [command(storage, workspace)],
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

/// How long the page waits for a remote member's host to answer.
const page_wait_ms = 5000

fn command(storage: store.Store, workspace: String) -> Command {
  Command(
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
    False,
    False,
    True,
    None,
    fn(_, caller, args) {
      let #(action, details) = page.args(args, "")
      case action, caller {
        "", _ -> Ok(listing(links.group(storage, workspace)))
        _, UserCall -> change(storage, workspace, action, details)
        _, _ -> Error("only a user links workspaces")
      }
    },
  )
}

fn listing(group: List(String)) -> command.Outcome {
  let rows = case group {
    [_] | [] -> []
    [own, ..linked] -> [
      page.detail_row(own, own, "here", page.Active, ""),
      ..list.map2(linked, presence.presences(linked, page_wait_ms), row)
    ]
  }
  Data(
    page.to_json(page.Document(
      "links",
      case list.length(group) {
        n if n > 1 -> int.to_string(n - 1) <> " linked"
        _ -> ""
      },
      "not linked · a links a workspace holding the same project",
      rows,
      [
        page.Action(
          "a",
          "link",
          "add",
          False,
          page.Text("workspace", False),
          False,
        ),
        page.Action("x", "unlink", "remove", True, page.NoInput, True),
      ],
      None,
    )),
  )
}

/// A linked member as the page shows it. A host that does not answer is not
/// a gone folder: the row says why, and nothing suggests removing it.
fn row(member: String, presence: Presence) -> page.Row {
  case presence {
    Here -> page.detail_row(member, member, "", page.Plain, "")
    Gone ->
      page.detail_row(
        member,
        member,
        "gone",
        page.Muted,
        "its folder no longer exists; its memory and work items stay until you remove it",
      )
    Unknown(target, why) -> {
      let #(badge, tone) = case why {
        ssh.Warming -> #("connecting", page.Muted)
        ssh.NeedsAuth(..) -> #("sign in", page.Warning)
        ssh.Unreachable(_) | ssh.Unsupported(_) -> #("unreachable", page.Muted)
      }
      page.detail_row(
        member,
        member,
        badge,
        tone,
        ssh.describe(target, why)
          <> "; its memory and work items are still read",
      )
    }
  }
}

fn change(
  storage: store.Store,
  workspace: String,
  action: String,
  details: String,
) -> Result(command.Outcome, String) {
  let group = links.group(storage, workspace)
  use #(message, notes) <- result.try(case action {
    "add" -> {
      use other <- result.try(
        location.workspace(details)
        |> result.map_error(fn(failure) { failure.detail })
        |> result.map(location.to_string),
      )
      use _ <- result.try(case other == workspace, list.contains(group, other) {
        True, _ -> Error("that is this workspace")
        _, True -> Error("already linked with " <> other)
        False, False -> Ok(Nil)
      })
      let theirs = links.group(storage, other)
      use _ <- result.try(links.link(storage, workspace, other))
      Ok(#(
        "linked with " <> other,
        list.append(joined(group, theirs), joined(theirs, group)),
      ))
    }
    "remove" -> {
      use _ <- result.try(case group, list.contains(group, details) {
        [_, _, ..], True -> Ok(Nil)
        _, _ -> Error(details <> " is not linked with this workspace")
      })
      use _ <- result.try(links.unlink(storage, details))
      let rest = list.filter(group, fn(member) { member != details })
      Ok(
        #(
          case details == workspace {
            True -> "left the group"
            False -> "unlinked " <> details
          },
          [
            #(details, left(rest)),
            ..list.map(rest, fn(member) { #(member, unlinked(details)) })
          ],
        ),
      )
    }
    _ -> Error("unknown action " <> action <> "; use add or remove")
  })
  let told = case tell(storage, notes) {
    0 -> "; no session was open to tell"
    1 -> "; told 1 open session"
    n -> "; told " <> int.to_string(n) <> " open sessions"
  }
  Ok(Data(json.object([#("message", json.string(message <> told))])))
}

/// The note for every workspace in `members` that now reads `others`. It
/// carries their memory as a new session's snapshot holds it, so a session
/// that opened before the link sees the same text without rebuilding its
/// prompt (and losing its prompt cache).
fn joined(
  members: List(String),
  others: List(String),
) -> List(#(String, StateOp)) {
  let names = string.join(others, ", ")
  let snapshot = case linked_memory(others) {
    "" -> ""
    memory -> " Their memory, as a new session's snapshot holds it:\n" <> memory
  }
  let note =
    note(
      "linked with " <> names,
      "The user linked this workspace with "
        <> names
        <> ": memory and the work ledger now also read their notes and items. What you write stays in this workspace."
        <> snapshot,
    )
  list.map(members, fn(member) { #(member, note) })
}

fn left(rest: List(String)) -> StateOp {
  let names = string.join(rest, ", ")
  note(
    "unlinked from " <> names,
    "The user unlinked this workspace from "
      <> names
      <> ": memory and the work ledger cover only this workspace again. Their notes in this session's memory snapshot are left over from before; nothing was deleted.",
  )
}

fn unlinked(member: String) -> StateOp {
  note(
    "unlinked " <> member,
    "The user unlinked "
      <> member
      <> " from this workspace's group: its memory and work items are no longer read here, and its notes in this session's memory snapshot are left over from before; nothing was deleted.",
  )
}

fn note(display: String, text: String) -> StateOp {
  Note("links", display, "<system-note>" <> text <> "</system-note>")
}

/// Queue each workspace's note in every open session there, answering how
/// many took it. A closed session needs none: it composes its snapshot
/// afresh when it opens.
fn tell(storage: store.Store, notes: List(#(String, StateOp))) -> Int {
  conversation.list(storage)
  |> result.unwrap([])
  |> list.count(fn(info) {
    case list.key_find(notes, info.cwd) {
      Ok(note) -> result.is_ok(command.context(info.id).state(note))
      Error(Nil) -> False
    }
  })
}

@external(erlang, "albedo_memory", "linked")
fn linked_memory(workspaces: List(String)) -> String
