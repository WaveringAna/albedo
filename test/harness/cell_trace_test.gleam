//// Traces are written by the tool path and read back through the session.

import albedo/harness/runtime
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/string
import gleeunit/should

fn call(id: String, code: String) -> types.ToolCall {
  let arguments =
    json.object([
      #("code", json.string(code)),
      #("timeout_ms", json.int(5000)),
    ])
    |> json.to_string
  types.ToolCall(id, "python", arguments)
}

fn value(output: String) -> String {
  let assert Ok(value) =
    json.parse(output, decode.field("value", decode.string, decode.success))
  value
}

pub fn a_cell_trace_is_readable_from_the_session_test() {
  let assert Ok(host) = runtime.start(":memory:")
  let assert Ok(session) = runtime.open_session(host, "a", "/tmp")
  let assert Ok(types.ToolOutput(_, written)) =
    runtime.invoke(
      host,
      session,
      call(
        "one",
        "import uuid\nfrom pathlib import Path\nPath('/tmp/albedo_trace_probe.txt').write_text(uuid.uuid4().hex)",
      ),
    )
  written |> string.contains("\"status\":\"ok\"") |> should.be_true
  let assert Ok(types.ToolOutput(_, read)) =
    runtime.invoke(
      host,
      session,
      call(
        "two",
        "trace = await cells.trace('a/one')\n[change['path'] for change in trace['changes']]",
      ),
    )
  value(read) |> should.equal("['/tmp/albedo_trace_probe.txt']")
  let assert Ok(types.ToolOutput(_, missing)) =
    runtime.invoke(
      host,
      session,
      call(
        "three",
        "try:\n    await cells.trace('a/three')\nexcept Exception as error:\n    print(error)",
      ),
    )
  missing
  |> string.contains("recorded when the cell finishes")
  |> should.be_true
  runtime.stop(host)
}
