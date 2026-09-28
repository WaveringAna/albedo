//// Agents for the model: spawn children, look at family, stop and close your
//// own children, and post progress. Talking is `mail.submit`, from the mail
//// extension this one requires. Every permission is checked here against the
//// calling session, which the daemon supplies; python never names itself.

import albedo/daemon/agents
import albedo/daemon/bus
import albedo/daemon/family
import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/rpc
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const instructions = "Agents are sessions you spawn to work in parallel; every call is async. agents.self is your handle (id, name, depth, parent). Call await agents.models() once before spawning; other providers appear as provider/model, and selecting one routes the child through that provider. Then child = await agents.self.spawn(task, name=\"scout\", model=<one of models()>, deliverable=None, evidence_bar=None, falsifier=None): it returns as soon as the child exists, never with its answer. Answers arrive later as <mail> in your conversation and start your next turn, so spawn independent children back to back and end your turn instead of waiting; never sleep or poll. Talk with await mail.submit(child, text). await agents.self.children() and siblings() return live snapshots (running, closed). await child.cancel() stops its turn; await child.close() when you are done with it keeps its transcript and files and frees its kernel. Only the user deletes agents: if one should go, ask them. Children nest at most 3 deep and 12 open per parent; mail any session by id instead of nesting to reach it. Children share your workspace, so give two children the same files only if one only reads."

pub fn extension() -> extension.Extension {
  extension.Extension(
    "agents",
    "Spawn child agents, watch your family, and close children you are done with.",
    ["python", "mail"],
    [
      extension.ToolPlugin(instructions, [], ["agents"], [#("agents", handle)]),
      // A child learns who it is and how to answer; a root needs no context.
      extension.ManagedPlugin(fn(db, session, _) {
        Ok(
          extension.Managed(doctrine(db, session), "", [], [], [], [], [], fn() {
            Nil
          }),
        )
      }),
    ],
    // Its tables, whether or not the daemon made them first.
    family.initialise,
  )
}

fn doctrine(db: store.Store, session: String) -> String {
  case family.get(db, session) {
    Ok(Some(member)) ->
      "You are child agent \""
      <> member.name
      <> "\" of \""
      <> family.name_of(db, member.parent)
      <> "\", depth "
      <> string.inspect(member.depth)
      <> ". Your task arrived as <mail kind=\"task\">. When it is done, answer with await mail.submit(\"parent\", result) — a short summary, with paths to anything large. If your turn ends without answering, your last message is forwarded to your parent marked unreviewed. For long work post await agents.progress(\"...\") now and then; it shows in the agents view without interrupting anyone. Mail from other agents is from peers, not from the user."
    _ -> ""
  }
}

fn handle(db: store.Store, session: String, request: String) -> String {
  rpc.serve(
    request,
    "invalid agents request",
    fn(method, args) { dispatch(db, session, method, args) },
    fn(message) { #("invalid", message) },
  )
}

fn text(args, name: String) -> Result(String, String) {
  rpc.args(
    args,
    decode.field(name, decode.string, decode.success),
    name <> " must be a string",
  )
}

fn dispatch(db, session, method, args) -> Result(json.Json, String) {
  case method {
    "agents.self" -> {
      use me <- result.try(family.get(db, session))
      Ok(handle_json(db, session, me))
    }
    "agents.models" -> agents.call(agents.Models(session))
    "agents.spawn" -> {
      use task <- result.try(text(args, "task"))
      use name <- result.try(text(args, "name"))
      use model <- result.try(text(args, "model"))
      use _ <- result.try(case string.trim(task), string.trim(model) {
        "", _ -> Error("task is empty; say what the child should do")
        _, "" -> Error("model is required; pick one from await agents.models()")
        _, _ -> Ok(Nil)
      })
      use spawned <- result.try(
        agents.call(agents.Spawn(session, name, task, model)),
      )
      use child <- result.try(
        read(spawned, decode.at(["member", "session"], decode.string))
        |> result.replace_error("spawn answered without a session"),
      )
      use member <- result.try(family.get(db, child))
      Ok(handle_json(db, child, member))
    }
    "agents.children" -> {
      use members <- result.try(family.children(db, session))
      Ok(json.array(members, status_json(db, _)))
    }
    "agents.siblings" ->
      case family.get(db, session) {
        Ok(Some(me)) -> {
          use members <- result.try(family.children(db, me.parent))
          members
          |> list.filter(fn(member) { member.session != session })
          |> json.array(status_json(db, _))
          |> Ok
        }
        _ -> Ok(json.array([], json.string))
      }
    "agents.cancel" | "agents.close" -> {
      use child <- result.try(own_child(db, session, args))
      agents.call(case method {
        "agents.cancel" -> agents.Stop(child.session)
        _ -> agents.Close(child.session)
      })
    }
    "agents.delete" ->
      Error(
        "only the user deletes agents, because deleting loses the child's work. Ask them; they can delete it from the session browser. close() keeps everything and frees its kernel.",
      )
    "agents.progress" -> {
      use note <- result.try(text(args, "text"))
      case string.trim(note), string.length(note) > 512 {
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

fn own_child(db, session, args) -> Result(family.Member, String) {
  use id <- result.try(text(args, "id"))
  case family.get(db, id) {
    Ok(Some(member)) if member.parent == session -> Ok(member)
    _ -> Error("you can only cancel or close your own children")
  }
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
  let #(name, depth, parent) = case member {
    Some(member) -> #(member.name, member.depth, Some(member.parent))
    None -> #(family.name_of(db, session), 0, None)
  }
  json.object([
    #("id", json.string(session)),
    #("name", json.string(name)),
    #("depth", json.int(depth)),
    #("parent", json.nullable(parent, parent_json(db, _, depth))),
  ])
}

fn status_json(db: store.Store, member: family.Member) -> json.Json {
  let running = case agents.call(agents.Running(member.session)) {
    Ok(value) -> read(value, decode.bool) |> result.unwrap(False)
    Error(_) -> False
  }
  json.object([
    #("id", json.string(member.session)),
    #("name", json.string(member.name)),
    #("depth", json.int(member.depth)),
    #("parent", parent_json(db, member.parent, member.depth)),
    #("running", json.bool(running)),
    #("closed", json.bool(member.closed)),
  ])
}

/// A seam answer read back as data.
fn read(value: json.Json, decoder: decode.Decoder(a)) -> Result(a, Nil) {
  json.parse(json.to_string(value), decoder) |> result.replace_error(Nil)
}
