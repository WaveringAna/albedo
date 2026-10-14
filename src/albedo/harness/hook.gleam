//// Hooks: what a turn asks its extensions as it goes, and how their answers
//// combine. Any managed extension may contribute one; see robot-docs/hooks.md.

import albedo/daemon/note
import albedo/harness/host
import albedo/harness/protect
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

pub type Event {
  /// A user message is about to start a turn.
  Prompted(text: String)
  /// A tool call is about to run.
  Calling(call: Call)
  /// It finished; a refused call's `output` is its refusal.
  Called(call: Call, output: String, started_ms: Int, finished_ms: Int)
  /// The model ended its turn without calling a tool; hooks already kept
  /// this turn going `held` times.
  Stopping(reply: String, held: Int)
}

/// A model tool call, or `run`, `files.edit` or `files.write` inside a cell,
/// whose `within` is the model call that ran the cell.
pub type Call {
  Call(id: String, name: String, arguments: String, within: Option(String))
}

pub type Verdict {
  Verdict(
    /// Refuse the call or prompt, or (`Stopping`) keep the turn going; the
    /// model reads the reason.
    block: Option(String),
    /// `Calling`: the JSON arguments to run the call with instead.
    arguments: Option(String),
    /// Model-visible text, committed as user input.
    context: List(String),
    /// Shown to the user, never to the model.
    notes: List(String),
    /// End the turn.
    halt: Option(String),
  )
}

pub const proceed = Verdict(None, None, [], [], None)

/// A contributed hook and the extension it belongs to.
pub type Hook =
  #(String, fn(Event) -> Verdict)

/// What every hook said, merged, and which extension the block or halt
/// that won came from.
pub type Answer {
  Answer(verdict: Verdict, by: String)
}

/// Asks every hook in order. The first block, rewrite or halt wins, a later
/// hook sees the arguments an earlier one rewrote, and a crashed hook is a
/// note. Context comes back as notes naming the extension that wrote it, so
/// the transcript never shows it as the user's.
pub fn ask(hooks: List(Hook), event: Event) -> Answer {
  let #(_, answer) =
    list.fold(hooks, #(event, Answer(proceed, "")), fn(state, hook) {
      let #(event, Answer(verdict, by)) = state
      let #(name, ask) = hook
      let next = case protect.attempt(fn() { ask(event) }) {
        Ok(next) ->
          Verdict(..next, context: list.map(next.context, note.wrap(name, _)))
        Error(crash) ->
          Verdict(..proceed, notes: [name <> " hook crashed: " <> crash])
      }
      let event = case event, next.arguments {
        Calling(call), Some(arguments) -> Calling(Call(..call, arguments:))
        _, _ -> event
      }
      let by = case verdict.block, verdict.halt, next.block, next.halt {
        None, None, Some(_), _ | None, None, _, Some(_) -> name
        _, _, _, _ -> by
      }
      #(event, Answer(merge(verdict, next), by))
    })
  answer
}

/// `reason`, from the extension `by`, as input the model reads.
pub fn input(by: String, reason: String) -> String {
  note.wrap(by, reason)
}

fn merge(first: Verdict, next: Verdict) -> Verdict {
  Verdict(
    block: option.or(first.block, next.block),
    arguments: option.or(first.arguments, next.arguments),
    context: list.append(first.context, next.context),
    notes: list.append(first.notes, next.notes),
    halt: option.or(first.halt, next.halt),
  )
}

/// A note's body, for text that goes somewhere notes are not read.
fn body(text: String) -> String {
  case note.parse(text) {
    Some(#(_, body)) -> body
    None -> text
  }
}

/// The `hook.call` and `hook.called` host route a kernel reports its inner
/// calls through; a halt inside a cell refuses the call.
pub fn route(hooks: List(Hook)) -> host.Route {
  #("hook", fn(_context, method, args) {
    let call = {
      use id <- decode.field("id", decode.string)
      use name <- decode.field("name", decode.string)
      use arguments <- decode.field("arguments", decode.string)
      use within <- decode.field("within", decode.optional(decode.string))
      decode.success(Call(id, name, arguments, within))
    }
    let event = case method {
      "hook.call" -> decode.run(args, decode.map(call, Calling))
      _ ->
        decode.run(args, {
          use call <- decode.field("call", call)
          use output <- decode.field("output", decode.string)
          use started <- decode.field("started_ms", decode.int)
          use finished <- decode.field("finished_ms", decode.int)
          decode.success(Called(call, output, started, finished))
        })
    }
    case event {
      Error(_) -> Error(#("invalid", "invalid hook event"))
      Ok(event) -> {
        let verdict = ask(hooks, event).verdict
        Ok(
          json.object([
            #(
              "block",
              json.nullable(option.or(verdict.block, verdict.halt), json.string),
            ),
            #("arguments", json.nullable(verdict.arguments, json.string)),
            #(
              "context",
              json.array(list.map(verdict.context, body), json.string),
            ),
            #("notes", json.array(verdict.notes, json.string)),
          ]),
        )
      }
    }
  })
}
