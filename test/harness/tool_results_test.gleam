//// A request pairs every tool_use with its tool_result: a late result moves
//// back beside its call, a call no result answers gets `unpaired_result`,
//// and a result whose call the fold dropped stays out of the request. Turn
//// starts recover pending calls before any request is built, so no e2e
//// request reaches the builder with the inputs that broke pairing here; the
//// fold damage this repairs is only visible at the request boundary.

import albedo/daemon/message_content
import albedo/daemon/tool_results
import albedo/openai_api/replay
import albedo/openai_api/types
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should

fn calls(ids: List(String)) -> types.Input {
  let assert Ok(item) =
    json.parse(
      json.to_string(replay.message(
        json.string(""),
        "",
        None,
        list.map(ids, fn(id) { types.ToolCall(id, "python", "{}") }),
      )),
      types.replay_decoder(types.ChatCompletions),
    )
  types.Replay(item)
}

fn note(text: String) -> types.Input {
  types.User(text)
}

/// Each input as what a request sees it as: the calls a provider item makes,
/// a tool result's id, or a plain row.
fn shape(inputs: List(types.Input)) -> List(#(String, String)) {
  list.map(inputs, fn(input) {
    case input {
      types.ToolOutput(id, _, _) -> #("result", id)
      types.Replay(_) -> {
        let ids =
          message_content.calls(input)
          |> list.map(fn(call) { call.id })
          |> string.join(",")
        #("calls", ids)
      }
      types.User(text) -> #("user", text)
      types.UserImage(text, _) -> #("user", text)
      types.Assistant(text) -> #("assistant", text)
    }
  })
}

pub fn a_call_nothing_answers_gets_a_result_test() -> Nil {
  let inputs = [calls(["toolu_a"]), note("a note saved while the call ran")]
  shape(tool_results.pair(inputs))
  |> should.equal([
    #("calls", "toolu_a"),
    #("result", "toolu_a"),
    #("user", "a note saved while the call ran"),
  ])
  let assert [_, types.ToolOutput(_, text, []), _] = tool_results.pair(inputs)
  text |> should.equal(tool_results.unpaired_result)
}

pub fn a_result_separated_from_its_call_moves_beside_it_test() -> Nil {
  let inputs = [
    calls(["toolu_a"]),
    note("a note saved while the call ran"),
    types.ToolOutput("toolu_a", "ran", []),
  ]
  shape(tool_results.pair(inputs))
  |> should.equal([
    #("calls", "toolu_a"),
    #("result", "toolu_a"),
    #("user", "a note saved while the call ran"),
  ])
}

pub fn a_result_the_fold_dropped_leaves_its_call_a_placeholder_test() -> Nil {
  let inputs = [
    calls(["toolu_a", "toolu_b"]),
    types.ToolOutput("toolu_a", "ran", []),
    note("later"),
  ]
  shape(tool_results.pair(inputs))
  |> should.equal([
    #("calls", "toolu_a,toolu_b"),
    #("result", "toolu_a"),
    #("result", "toolu_b"),
    #("user", "later"),
  ])
}

pub fn a_result_whose_call_the_fold_dropped_stays_out_test() -> Nil {
  let inputs = [
    note("the call was replaced by a summary"),
    types.ToolOutput("toolu_gone", "ran", []),
  ]
  shape(tool_results.pair(inputs))
  |> should.equal([#("user", "the call was replaced by a summary")])
}

pub fn pairing_is_idempotent_test() -> Nil {
  let inputs = [
    calls(["toolu_a", "toolu_b"]),
    note("between"),
    types.ToolOutput("toolu_b", "ran", []),
    types.ToolOutput("toolu_b", "ran twice", []),
  ]
  let paired = tool_results.pair(inputs)
  tool_results.pair(paired) |> should.equal(paired)
  shape(paired)
  |> should.equal([
    #("calls", "toolu_a,toolu_b"),
    #("result", "toolu_b"),
    #("result", "toolu_a"),
    #("user", "between"),
  ])
}

pub fn repeated_call_ids_across_turns_keep_each_turns_result_test() -> Nil {
  let inputs = [
    calls(["call_0"]),
    types.ToolOutput("call_0", "first", []),
    note("second prompt"),
    calls(["call_0"]),
    types.ToolOutput("call_0", "second", []),
  ]
  tool_results.pair(inputs) |> should.equal(inputs)
  tool_results.unanswered(inputs) |> should.equal([])

  let pending_tail = [
    calls(["call_0"]),
    types.ToolOutput("call_0", "first", []),
    note("second prompt"),
    calls(["call_0"]),
  ]
  tool_results.unanswered(pending_tail)
  |> should.equal([types.ToolCall("call_0", "python", "{}")])
  tool_results.pair(pending_tail)
  |> should.equal(
    list.append(pending_tail, [
      types.ToolOutput("call_0", tool_results.unpaired_result, []),
    ]),
  )
}
