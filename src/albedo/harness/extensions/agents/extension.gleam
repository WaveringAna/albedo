//// Agents for the model: spawn children, look up any session and read its
//// messages, stop and close your own children, and post progress. Talking is
//// `mail.submit`, from the mail extension this one requires. Every permission
//// is checked here against the calling session, which the daemon supplies;
//// python never names itself.

import albedo/daemon/agents
import albedo/daemon/bus
import albedo/daemon/family
import albedo/daemon/mail
import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/extensions/agents/sessions
import albedo/harness/hook
import albedo/harness/host
import albedo/harness/rpc
import albedo/harness/search
import albedo/harness/tool
import albedo/text_scalars
import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

const instructions =
  "Agents are sessions you spawn to work in parallel; every call is async. A lead session can keep a few long-lived peers for distinct areas, reusing useful context and starting fresh when context is unrelated; the right set depends on the project. agents.self is your handle (id, name, depth, parent). Call await agents.models() once before spawning; other providers appear as provider/model, and selecting one routes the child through that provider. Then child = await agents.self.spawn(task, name=\"scout\", model=<one of models()>, deliverable=None, evidence_bar=None, falsifier=None, verifier=None): it returns as soon as the child exists, never with its answer (verifier is an optional shell command that must exit 0 before the child can mail its parent or finish). Answers arrive later as <mail> in your conversation and start your next turn, so spawn independent children back to back and end your turn instead of waiting; never sleep or poll. Talk with await mail.submit(child, text). await agents.self.children() and siblings() return live snapshots (running, closed). running=False means no active turn; a new child may still be waiting for its kernel and have no transcript yet. It does not prove spawn failed; wait for its mail rather than cancelling it on that snapshot. await child.cancel() stops its turn, and child.cancel(tree=True) the turns of everything beneath it; await agents.cancel_all(tree=True) stops every child you have, and their descendants, in one call, so use it when the user says to stop the swarm; await child.close() when you are done with it keeps its messages and files and frees its kernel. await agents.get(to) returns a live handle for \"parent\", a family name, or any session id. On any handle, await h.messages(seq=0, offset=0, limit=4000) reads a page of that session's messages from row seq on (content, next_offset) and await h.search_messages(pattern) finds rows by seq: any session may read any other, so you can see what a child or another session did without waiting for mail. await agents.sessions(query=\"\", cwd=None, limit=20, offset=0) lists every session, most recently active first, as snapshots that also carry cwd, model, last_active, and matches; with a query it keeps sessions whose title or name contains it or whose messages do, and matches holds up to 3 of each one's newest matching rows as {seq, preview} to read with messages(seq=...). cwd keeps one directory. Only the user deletes agents: if one should go, ask them. Children nest at most 3 deep and 12 open per parent; mail any session by id instead of nesting to reach it. Children share your workspace, so give two children the same files only if one only reads."

pub fn extension() -> extension.Extension {
  extension.Extension(
    "agents",
    "Spawn child agents, watch your family, and close children you are done with.",
    ["python", "mail"],
    [
      extension.ToolPlugin(instructions, [], ["agents"], [
        #("agents", fn(context: host.Context, method, args) {
          handle(context.store, context.session, method, args)
        }),
      ]),
      // The hook is cheap for roots with no requests and keeps prompt context stable.
      extension.ManagedPlugin(fn(db, session, _) {
        let context = case family.get(db, session) {
          Ok(Some(member)) -> doctrine(db, member)
          _ -> ""
        }
        Ok(
          extension.Managed(
            ..extension.empty(),
            context: context,
            hook: Some(answered(db, session, _)),
          ),
        )
      }),
    ],
    // Its tables, whether or not the daemon made them first.
    family.initialise,
  )
}

fn doctrine(db: store.Store, member: family.Member) -> String {
  "You are child agent \""
  <> member.name
  <> "\" of \""
  <> family.name_of(db, member.parent)
  <> "\", depth "
  <> string.inspect(member.depth)
  <> ". Your task arrived as <mail kind=\"task\">. When it is done, answer with await mail.submit(\"parent\", result) — a short summary, with paths to anything large. To ask your parent a question or request clarification, use await mail.request(\"parent\", question). If a verifier command is set and you are blocked, report it with await mail.submit(\"parent\", blocker, blocker=True). If you finish without answering you are reminded once; a turn that still ends without an answer forwards your last message to your parent marked unreviewed. For long work post await agents.progress(\"...\") now and then; it shows in the agents view without interrupting anyone. Mail from other agents is from peers, not from the user."
}

/// Keeps a child's turn going when it owes a reply or its parent's verifier
/// gate fails, and refuses `mail.submit` to the parent until the gate passes.
fn answered(
  db: store.Store,
  session: String,
  event: hook.Event,
) -> hook.Verdict {
  case event {
    hook.Calling(call) if call.name == "mail.submit" -> {
      let decoder = {
        use to <- decode.field("to", decode.string)
        use blocker <- decode.optional_field("blocker", False, decode.bool)
        decode.success(#(to, blocker))
      }
      case
        decode.run(
          json.parse(call.arguments, decode.dynamic)
            |> result.unwrap(dynamic.nil()),
          decoder,
        )
      {
        Ok(#(to, False)) ->
          case family.resolve(db, session, to), family.get(db, session) {
            Ok(address), Ok(Some(member)) if address.session == member.parent ->
              case verify_child(db, session) {
                Ok(Nil) -> hook.proceed
                Error(detail) ->
                  hook.Verdict(
                    ..hook.proceed,
                    block: Some(
                      detail
                      <> "\n\nYou cannot submit task completion while the verifier is failing. Fix the failure, ask a question with await mail.request(\"parent\", <question>), or report a blocker with await mail.submit(\"parent\", <blocker>, blocker=True).",
                    ),
                  )
              }
            _, _ -> hook.proceed
          }
        _ -> hook.proceed
      }
    }
    hook.Stopping(held:, ..) ->
      case mail.owed_requesters(db, session) {
        Ok([first, ..rest] as requesters) ->
          case requesters, family.get(db, session) {
            [parent], Ok(Some(member)) if member.parent == parent ->
              case verify_child(db, session) {
                Error(detail) ->
                  hook.Verdict(
                    ..hook.proceed,
                    block: Some(
                      detail
                      <> "\n\nFix the failure so the verifier exits 0, then send your result with await mail.submit(\"parent\", result).\nIf you need help from your parent, ask with await mail.request(\"parent\", <question>), or report a blocker with await mail.submit(\"parent\", <blocker>, blocker=True).",
                    ),
                  )
                Ok(Nil) if held == 0 ->
                  hook.Verdict(
                    ..hook.proceed,
                    block: Some(
                      "You have not answered your parent yet. Send your result with await mail.submit(\"parent\", result) before you finish.",
                    ),
                  )
                Ok(Nil) -> hook.proceed
              }
            _, _ if held == 0 ->
              hook.Verdict(
                ..hook.proceed,
                block: Some(
                  "You owe a reply to "
                  <> string.join([first, ..rest], ", ")
                  <> ". Send it with await mail.submit(\"<id>\", result) before you finish.",
                ),
              )
            _, _ -> hook.proceed
          }
        _ -> hook.proceed
      }
    _ -> hook.proceed
  }
}

fn verify_child(db: store.Store, session: String) -> Result(Nil, String) {
  case family.verifier(db, session) {
    Ok(Some(#(cwd, command))) ->
      case run_verifier(cwd, command) {
        Ok(_) -> Ok(Nil)
        Error(detail) -> Error(detail)
      }
    _ -> Ok(Nil)
  }
}

@external(erlang, "albedo_verifier", "check")
fn run_verifier(cwd: String, command: String) -> Result(String, String)

fn handle(
  db: store.Store,
  session: String,
  method: String,
  args: dynamic.Dynamic,
) -> Result(json.Json, #(String, String)) {
  rpc.serve(
    method,
    args,
    fn(method, args) { dispatch(db, session, method, args) },
    fn(message) { #("invalid", message) },
  )
}

fn text(args: dynamic.Dynamic, name: String) -> Result(String, String) {
  rpc.args(
    args,
    decode.field(name, decode.string, decode.success),
    name <> " must be a string",
  )
}

fn dispatch(
  db: store.Store,
  session: String,
  method: String,
  args: dynamic.Dynamic,
) -> Result(json.Json, String) {
  case method {
    "agents.self" -> {
      use me <- result.try(family.get(db, session))
      Ok(handle_json(db, session, me))
    }
    "agents.models" ->
      case agents.call(agents.Models(session)) {
        Ok(agents.AvailableModels(models)) ->
          Ok(json.array(models, json.string))
        Ok(_) -> Ok(json.array([], json.string))
        Error(error) -> Error(error)
      }
    "agents.start" -> {
      use task <- result.try(text(args, "task"))
      use name <- result.try(text(args, "name"))
      use model <- result.try(text(args, "model"))
      let cwd =
        decode.run(
          args,
          decode.optional_field("cwd", "", decode.string, decode.success),
        )
        |> result.unwrap("")
      let role =
        decode.run(
          args,
          decode.optional_field("role", "", decode.string, decode.success),
        )
        |> result.unwrap("")
      use started <- result.try(
        agents.call(agents.Start(session, task, name, model, cwd, role)),
      )
      case started {
        agents.Started(info) -> Ok(handle_json(db, info.id, None))
        _ -> Error("start answered unexpectedly")
      }
    }
    "agents.spawn" -> {
      use task <- result.try(text(args, "task"))
      use name <- result.try(text(args, "name"))
      use model <- result.try(text(args, "model"))
      let verifier =
        decode.run(
          args,
          decode.optional_field("verifier", "", decode.string, decode.success),
        )
        |> result.unwrap("")
        |> string.trim
      use _ <- result.try(
        case
          string.trim(task),
          string.trim(model),
          text_scalars.length(verifier) <= 4096
        {
          "", _, _ -> Error("task is empty; say what the child should do")
          _, "", _ ->
            Error("model is required; pick one from await agents.models()")
          _, _, False -> Error("verifier is at most 4096 characters")
          _, _, True -> Ok(Nil)
        },
      )
      use spawned <- result.try(
        agents.call(agents.Spawn(session, name, task, model)),
      )
      case spawned {
        agents.Spawned(member) -> {
          use _ <- result.try(case verifier {
            "" -> Ok(Nil)
            _ -> family.set_verifier(db, member.session, verifier)
          })
          Ok(handle_json(db, member.session, Some(member)))
        }
        _ -> Error("spawn answered unexpectedly")
      }
    }
    "agents.get" -> {
      use to <- result.try(text(args, "to"))
      use address <- result.try(family.resolve(db, session, to))
      use member <- result.try(family.get(db, address.session))
      Ok(status_json(db, address.session, member))
    }
    "agents.children" -> {
      use members <- result.try(family.children(db, session))
      Ok(json.array(members, member_status(db, _)))
    }
    "agents.siblings" ->
      case family.get(db, session) {
        Ok(Some(me)) -> {
          use members <- result.try(family.children(db, me.parent))
          members
          |> list.filter(fn(member) { member.session != session })
          |> json.array(member_status(db, _))
          |> Ok
        }
        _ -> Ok(json.array([], json.string))
      }
    "agents.close" -> {
      use child <- result.try(own_target(db, session, args))
      agents.call(agents.Close(child))
      |> result.replace(json.bool(True))
    }
    "agents.cancel" -> {
      use child_id <- result.try(own_target(db, session, args))
      use tree <- result.try(tree_flag(args))
      use child <- result.try(family.get(db, child_id))
      case child {
        Some(member) -> stop_all(db, [member], tree)
        None ->
          agents.call(agents.Stop(child_id))
          |> result.replace(json.array([], json.string))
      }
    }
    "agents.cancel_all" -> {
      use tree <- result.try(tree_flag(args))
      use children <- result.try(family.children(db, session))
      stop_all(db, children, tree)
    }
    "agents.messages" -> {
      use target <- result.try(addressed(db, session, args))
      use #(seq, through, offset, limit) <- result.try(rpc.args(
        args,
        {
          use seq <- decode.field("seq", decode.int)
          use through <- decode.field("through", decode.optional(decode.int))
          use offset <- decode.field("offset", decode.int)
          use limit <- decode.field("limit", decode.int)
          decode.success(#(seq, through, offset, limit))
        },
        "seq, offset and limit must be integers; through an integer or null",
      ))
      tool.transcript_read(db, target, seq, through, offset, limit)
    }
    "agents.search_messages" -> {
      use target <- result.try(addressed(db, session, args))
      use #(pattern, limit, offset, after, before) <- result.try(rpc.args(
        args,
        {
          use pattern <- decode.field("pattern", decode.string)
          use limit <- decode.field("limit", decode.int)
          use offset <- decode.field("offset", decode.int)
          use after <- decode.field("after_seq", decode.optional(decode.int))
          use before <- decode.field("before_seq", decode.optional(decode.int))
          decode.success(#(pattern, limit, offset, after, before))
        },
        "pattern must be a string; limit and offset integers; after_seq and before_seq integers or null",
      ))
      search.transcript_grep(
        db,
        target,
        pattern,
        limit,
        offset,
        after,
        before,
        target == session,
      )
    }
    "agents.sessions" -> {
      use #(query, cwd, limit, offset) <- result.try(rpc.args(
        args,
        {
          use query <- decode.field("query", decode.string)
          use cwd <- decode.field("cwd", decode.string)
          use limit <- decode.field("limit", decode.int)
          use offset <- decode.field("offset", decode.int)
          decode.success(#(query, cwd, limit, offset))
        },
        "query and cwd must be strings; limit and offset integers",
      ))
      use found <- result.try(sessions.find(db, session, query, cwd))
      found
      |> list.drop(int.max(offset, 0))
      |> list.take(int.clamp(limit, 1, 100))
      |> json.array(found_json(db, _))
      |> Ok
    }
    "agents.delete" ->
      Error(
        "only the user deletes agents, because deleting loses the child's work. Ask them; they can delete it from the session browser. close() keeps everything and frees its kernel.",
      )
    "agents.set_role" -> {
      use role <- result.try(text(args, "role"))
      let target =
        decode.run(
          args,
          decode.optional_field(
            "id",
            None,
            decode.optional(decode.string),
            decode.success,
          ),
        )
        |> result.unwrap(None)
        |> option.unwrap(session)
      use _ <- result.try(
        case target == session || owns_target(db, session, target) {
          True -> Ok(Nil)
          False ->
            Error("you can only set your own, a child, or a peer you started")
        },
      )
      family.set_role(db, target, role) |> result.map(fn(_) { json.bool(True) })
    }
    "agents.progress" -> {
      use note <- result.try(text(args, "text"))
      case string.trim(note), text_scalars.length(note) > 512 {
        "", _ -> Error("progress text is empty")
        _, True ->
          Error("progress is at most 512 characters; mail anything longer")
        _, False -> {
          bus.progress(session, note)
          Ok(json.bool(True))
        }
      }
    }
    _ -> Error("unknown agents call " <> method)
  }
}

fn tree_flag(args: dynamic.Dynamic) -> Result(Bool, String) {
  rpc.args(
    args,
    decode.field("tree", decode.bool, decode.success),
    "tree must be a boolean",
  )
}

/// Interrupts each member's running turn, and with `tree` the turns of
/// everything beneath it, parents first so none can answer a stop by spawning.
/// Answers the sessions that were running.
fn stop_all(
  db: store.Store,
  members: List(family.Member),
  tree: Bool,
) -> Result(json.Json, String) {
  use stopped <- result.try(stop_each(db, members, tree))
  Ok(json.array(stopped, json.string))
}

fn stop_each(
  db: store.Store,
  members: List(family.Member),
  tree: Bool,
) -> Result(List(String), String) {
  list.try_fold(members, [], fn(stopped, member) {
    use reply <- result.try(agents.call(agents.Stop(member.session)))
    let running = case reply {
      agents.Stopped(running) -> running
      _ -> False
    }
    let stopped = case running {
      True -> list.append(stopped, [member.session])
      False -> stopped
    }
    case tree {
      False -> Ok(stopped)
      True -> {
        use below <- result.try(family.children(db, member.session))
        use more <- result.try(stop_each(db, below, tree))
        Ok(list.append(stopped, more))
      }
    }
  })
}

fn owns_target(db: store.Store, caller: String, target: String) -> Bool {
  case family.get(db, target), family.started_by(db, target) {
    Ok(Some(member)), _ if member.parent == caller -> True
    _, Ok(Some(owner)) if owner == caller -> True
    _, _ -> False
  }
}

fn own_target(
  db: store.Store,
  session: String,
  args: dynamic.Dynamic,
) -> Result(String, String) {
  use id <- result.try(text(args, "id"))
  case owns_target(db, session, id) {
    True -> Ok(id)
    False -> Error("you can only cancel or close your own children or peers")
  }
}

/// The session `args.id` names, as mail would resolve it. Reading is open to
/// every session: families only narrow who may stop whom.
fn addressed(
  db: store.Store,
  session: String,
  args: dynamic.Dynamic,
) -> Result(String, String) {
  use id <- result.try(text(args, "id"))
  family.resolve(db, session, id) |> result.map(fn(address) { address.session })
}

fn parent_json(db: store.Store, id: String, depth: Int) -> json.Json {
  json.object([
    #("id", json.string(id)),
    #("name", json.string(family.name_of(db, id))),
    #("depth", json.int(depth - 1)),
  ])
}

fn handle_json(
  db: store.Store,
  session: String,
  member: Option(family.Member),
) -> json.Json {
  json.object(handle_fields(db, session, member))
}

fn handle_fields(
  db: store.Store,
  session: String,
  member: Option(family.Member),
) -> List(#(String, json.Json)) {
  let #(name, depth, parent) = case member {
    Some(member) -> #(member.name, member.depth, Some(member.parent))
    None -> #(family.name_of(db, session), 0, None)
  }
  [
    #("id", json.string(session)),
    #("name", json.string(name)),
    #("depth", json.int(depth)),
    #("parent", json.nullable(parent, parent_json(db, _, depth))),
  ]
}

/// A handle with its live state; a root is never closed.
fn status_json(
  db: store.Store,
  session: String,
  member: Option(family.Member),
) -> json.Json {
  json.object(status_fields(db, session, member))
}

fn status_fields(
  db: store.Store,
  session: String,
  member: Option(family.Member),
) -> List(#(String, json.Json)) {
  let running = case agents.call(agents.Running(session)) {
    Ok(agents.RunningState(running)) -> running
    _ -> False
  }
  let closed = family.closed(db, session) |> result.unwrap(False)
  list.append(handle_fields(db, session, member), [
    #("running", json.bool(running)),
    #("closed", json.bool(closed)),
  ])
}

/// A snapshot as `agents.sessions()` lists it: also where it works, on which
/// model, when it last answered (unix seconds), and why a query matched it.
fn found_json(db: store.Store, found: sessions.Found) -> json.Json {
  let info = found.info
  let member = family.get(db, info.id) |> result.unwrap(None)
  json.object(list.append(
    status_fields(db, info.id, member),
    list.append(
      [
        #("cwd", json.string(info.cwd)),
        #("role", json.string(family.role(db, info.id) |> result.unwrap(""))),
        #(
          "started_by",
          json.nullable(
            family.started_by(db, info.id) |> result.unwrap(None),
            json.string,
          ),
        ),
        #("model", json.string(info.model)),
        #("last_active", json.nullable(info.last_assistant_at, json.int)),
        #(
          "matches",
          json.array(found.hits, fn(hit) {
            json.object([
              #("seq", json.int(hit.seq)),
              #("preview", json.string(hit.preview)),
            ])
          }),
        ),
      ],
      snapshot_fields(db, info.id),
    ),
  ))
}

fn snapshot_fields(
  db: store.Store,
  session: String,
) -> List(#(String, json.Json)) {
  let owed = mail.owed_requesters(db, session) |> result.unwrap([])
  let awaiting =
    store.read(
      db,
      "SELECT DISTINCT recipient FROM mail WHERE sender=? AND kind IN ('task','request') AND delivered_at IS NOT NULL",
      [sqlight.text(session)],
      decode.field(0, decode.string, decode.success),
    )
    |> result.unwrap([])
    |> list.filter(fn(target) {
      mail.owes_reply(db, target, session) == Ok(True)
    })
  let context_tokens =
    store.read(
      db,
      "SELECT usage_prompt_tokens FROM sessions WHERE id=?",
      [sqlight.text(session)],
      decode.field(0, decode.optional(decode.int), decode.success),
    )
    |> result.unwrap([])
    |> list.first
    |> result.unwrap(None)
  let pinned =
    store.read(
      db,
      "SELECT pinned FROM sessions WHERE id=?",
      [sqlight.text(session)],
      decode.field(0, decode.int, decode.success),
    )
    |> result.unwrap([])
    |> list.first
    |> result.unwrap(0)
    == 1
  [
    #("pinned", json.bool(pinned)),
    #("owed", json.int(list.length(owed))),
    #("awaiting", json.int(list.length(awaiting))),
    #("context_tokens", json.nullable(context_tokens, json.int)),
  ]
}

fn member_status(db: store.Store, member: family.Member) -> json.Json {
  status_json(db, member.session, Some(member))
}
