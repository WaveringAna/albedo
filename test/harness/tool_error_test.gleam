//// A refused retrieval call answers with an error payload the model can
//// correct, instead of ending the turn: subagents died whole on
//// "run failed: LCM node not found in this session" after handing a
//// transcript row seq to an LCM node tool.

import albedo/daemon/conversation
import albedo/daemon/family
import albedo/harness/extensions
import albedo/harness/extensions/lcm/memory as lcm_memory
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None}
import gleam/string
import gleeunit/should

fn host() -> #(runtime.Runtime, runtime.Session) {
  let assert Ok(host) =
    runtime.start_with_config(
      ":memory:",
      extensions.Config([lcm_memory.extension()], ["lcm-memory"]),
    )
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = family.initialise(ledger)
  let assert Ok(_) =
    conversation.create(
      ledger,
      conversation.Info(
        "tool-error-test",
        "new session",
        "/tmp",
        "provider",
        "model",
        types.Responses,
        conversation.Idle,
        None,
        None,
      ),
    )
  let assert Ok(session) = runtime.open_session(host, "tool-error-test", "/tmp")
  #(host, session)
}

fn answer(
  host: runtime.Runtime,
  session: runtime.Session,
  name: String,
  arguments: String,
) -> String {
  // The regression is Ok against Error: a refused read must not fail the run.
  let assert Ok(output) =
    runtime.invoke(
      host,
      session,
      types.ToolCall("call_1", name, arguments),
      types.any_images,
    )
  let assert types.ToolOutput(_, body, []) = output
  body
}

pub fn missing_lcm_node_answers_as_tool_output_test() -> Nil {
  let #(host, session) = host()
  // 35049 is a transcript row seq, the exact confusion that killed a child.
  let body = answer(host, session, "lcm_describe", "{\"id\":35049}")
  let assert Ok(reason) =
    json.parse(body, decode.field("error", decode.string, decode.success))
  string.contains(reason, "LCM node 35049 not found") |> should.be_true
  string.contains(reason, "transcript_read") |> should.be_true
  runtime.stop(host)
}

pub fn missing_summary_scope_answers_as_tool_output_test() -> Nil {
  let #(host, session) = host()
  let body =
    answer(
      host,
      session,
      "lcm_grep",
      "{\"pattern\":\"needle\",\"summary_id\":7}",
    )
  let assert Ok(reason) =
    json.parse(body, decode.field("error", decode.string, decode.success))
  string.contains(reason, "LCM node 7 not found") |> should.be_true
  runtime.stop(host)
}

pub fn answering_tools_still_answer_normally_test() -> Nil {
  let #(host, session) = host()
  let body = answer(host, session, "lcm_list", "{}")
  let assert Ok(total) =
    json.parse(body, decode.field("total", decode.int, decode.success))
  total |> should.equal(0)
  runtime.stop(host)
}
