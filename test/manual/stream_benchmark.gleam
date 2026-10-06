//// Run explicitly with: gleam run -m manual/stream_benchmark
//// Offline: frames and reduces synthetic Responses and Chat Completions
//// streams, and encodes a large request, printing time per run. Profile a
//// run with eprof for where the time goes.

import albedo/clock
import albedo/openai_api/request
import albedo/openai_api/sse
import albedo/openai_api/stream
import albedo/openai_api/types
import gleam/bit_array
import gleam/float
import gleam/int
import gleam/io
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}

const deltas = 20_000

const chunk_bytes = 1400

const runs = 10

pub fn main() -> Nil {
  let responses = chunks(responses_stream(deltas))
  let chat = chunks(chat_stream(deltas))
  time("responses stream", stream_bytes(responses), fn() {
    drive(types.Responses, responses)
  })
  time("chat stream", stream_bytes(chat), fn() {
    drive(types.ChatCompletions, chat)
  })
  let responses_request = large_request(types.Responses, 400, 40)
  let chat_request = large_request(types.ChatCompletions, 400, 40)
  time("encode responses request", 0, fn() {
    encode(types.Responses, responses_request)
  })
  time("encode chat request", 0, fn() {
    encode(types.ChatCompletions, chat_request)
  })
}

fn encode(protocol: types.Protocol, request: types.Request) -> String {
  request.encode(protocol, request)
  |> result.map(string_tree.byte_size)
  |> string.inspect
}

fn time(label: String, bytes: Int, run: fn() -> String) -> Nil {
  let summary = run()
  let started = clock.monotonic_ms()
  list.each(list.repeat(Nil, runs), fn(_) { run() })
  let per_run =
    int.to_float(clock.monotonic_ms() - started) /. int.to_float(runs)
  let rate = case bytes {
    0 -> ""
    _ ->
      "  "
      <> float.to_string(float.to_precision(
        int.to_float(bytes) /. per_run *. 1000.0 /. 1_048_576.0,
        1,
      ))
      <> " MB/s"
  }
  io.println(
    label
    <> ": "
    <> float.to_string(float.to_precision(per_run, 2))
    <> " ms/run"
    <> rate
    <> "  "
    <> summary,
  )
}

fn stream_bytes(chunks: List(BitArray)) -> Int {
  list.fold(chunks, 0, fn(total, chunk) { total + bit_array.byte_size(chunk) })
}

fn drive(protocol: types.Protocol, chunks: List(BitArray)) -> String {
  case run(sse.new(8 * 1024 * 1024), stream.new(protocol), chunks) {
    Ok(turn) ->
      "turn: "
      <> int.to_string(list.length(turn.output))
      <> " items, "
      <> int.to_string(list.length(turn.tool_calls))
      <> " calls, "
      <> string.inspect(turn.finish)
    Error(error) -> "error: " <> error
  }
}

type Step {
  Done(types.Turn)
  More(stream.State)
}

fn run(
  parser: sse.Parser,
  state: stream.State,
  chunks: List(BitArray),
) -> Result(types.Turn, String) {
  case chunks {
    [] -> Error("no terminal event")
    [chunk, ..rest] -> {
      use #(parser, events) <- result.try(
        sse.feed(parser, chunk) |> result.map_error(string.inspect),
      )
      case reduce(state, events) {
        Ok(Done(turn)) -> Ok(turn)
        Ok(More(state)) -> run(parser, state, rest)
        Error(error) -> Error(error)
      }
    }
  }
}

fn reduce(
  state: stream.State,
  events: List(sse.Event),
) -> Result(Step, String) {
  case events {
    [] -> Ok(More(state))
    [event, ..rest] ->
      case stream.feed(state, event) {
        Ok(#(state, _, None)) -> reduce(state, rest)
        Ok(#(_, _, Some(turn))) -> Ok(Done(turn))
        Error(error) -> Error(string.inspect(error))
      }
  }
}

fn chunks(stream: StringTree) -> List(BitArray) {
  split(bit_array.from_string(string_tree.to_string(stream)), [])
}

fn split(bytes: BitArray, acc: List(BitArray)) -> List(BitArray) {
  case bit_array.byte_size(bytes) <= chunk_bytes {
    True -> list.reverse([bytes, ..acc])
    False -> {
      let assert <<head:bytes-size(chunk_bytes), rest:bytes>> = bytes
      split(rest, [head, ..acc])
    }
  }
}

fn event(name: String, data: Json) -> StringTree {
  string_tree.from_strings([
    "event: ",
    name,
    "\ndata: ",
    json.to_string(data),
    "\n\n",
  ])
}

fn responses_stream(count: Int) -> StringTree {
  let message = fn(text: String) {
    json.object([
      #("id", json.string("msg_001")),
      #("type", json.string("message")),
      #("status", json.string("completed")),
      #("role", json.string("assistant")),
      #(
        "content",
        json.array(
          [
            json.object([
              #("type", json.string("output_text")),
              #("text", json.string(text)),
              #("annotations", json.array([], json.string)),
            ]),
          ],
          fn(part) { part },
        ),
      ),
    ])
  }
  let calls =
    range(1, 5)
    |> list.map(fn(i) {
      json.object([
        #("id", json.string("fc_" <> int.to_string(i))),
        #("type", json.string("function_call")),
        #("status", json.string("completed")),
        #("call_id", json.string("call_" <> int.to_string(i))),
        #("name", json.string("python")),
        #("arguments", json.string("{\"code\":\"print(1)\"}")),
      ])
    })
  let tokens =
    range(1, count)
    |> list.map(fn(i) { "token " <> int.to_string(i) <> " " })
  let deltas =
    list.index_map(tokens, fn(token, i) {
      event(
        "response.output_text.delta",
        json.object([
          #("type", json.string("response.output_text.delta")),
          #("sequence_number", json.int(i + 2)),
          #("item_id", json.string("msg_001")),
          #("output_index", json.int(0)),
          #("content_index", json.int(0)),
          #("delta", json.string(token)),
          #("logprobs", json.array([], json.string)),
        ]),
      )
    })
  let full = message(string.concat(tokens))
  string_tree.concat([
    event(
      "response.created",
      json.object([
        #("type", json.string("response.created")),
        #("sequence_number", json.int(0)),
        #(
          "response",
          json.object([
            #("id", json.string("resp_abc123")),
            #("status", json.string("in_progress")),
            #("output", json.array([], json.string)),
          ]),
        ),
      ]),
    ),
    event(
      "response.output_item.added",
      json.object([
        #("type", json.string("response.output_item.added")),
        #("sequence_number", json.int(1)),
        #("output_index", json.int(0)),
        #("item", message("")),
      ]),
    ),
    string_tree.concat(deltas),
    event(
      "response.output_item.done",
      json.object([
        #("type", json.string("response.output_item.done")),
        #("output_index", json.int(0)),
        #("item", full),
      ]),
    ),
    event(
      "response.completed",
      json.object([
        #("type", json.string("response.completed")),
        #(
          "response",
          json.object([
            #("id", json.string("resp_abc123")),
            #("status", json.string("completed")),
            #("output", json.preprocessed_array([full, ..calls])),
            #(
              "usage",
              json.object([
                #("input_tokens", json.int(1200)),
                #(
                  "input_tokens_details",
                  json.object([#("cached_tokens", json.int(1000))]),
                ),
                #("output_tokens", json.int(count)),
                #(
                  "output_tokens_details",
                  json.object([#("reasoning_tokens", json.int(0))]),
                ),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  ])
}

fn chat_stream(count: Int) -> StringTree {
  let chunk = fn(delta: Json, finish: Json) {
    string_tree.from_strings([
      "data: ",
      json.to_string(
        json.object([
          #("id", json.string("chatcmpl-abc")),
          #("object", json.string("chat.completion.chunk")),
          #("created", json.int(1_700_000_000)),
          #("model", json.string("gpt-x")),
          #(
            "choices",
            json.preprocessed_array([
              json.object([
                #("index", json.int(0)),
                #("delta", delta),
                #("logprobs", json.null()),
                #("finish_reason", finish),
              ]),
            ]),
          ),
          #("usage", json.null()),
        ]),
      ),
      "\n\n",
    ])
  }
  let deltas =
    range(1, count)
    |> list.map(fn(i) {
      chunk(
        json.object([
          #("content", json.string("token " <> int.to_string(i) <> " ")),
        ]),
        json.null(),
      )
    })
  let tool = fn(i: Int, fields: List(#(String, Json))) {
    chunk(
      json.object([
        #(
          "tool_calls",
          json.preprocessed_array([
            json.object([#("index", json.int(i)), ..fields]),
          ]),
        ),
      ]),
      json.null(),
    )
  }
  let opened =
    range(0, 4)
    |> list.map(fn(i) {
      tool(i, [
        #("id", json.string("call_" <> int.to_string(i))),
        #("type", json.string("function")),
        #(
          "function",
          json.object([
            #("name", json.string("python")),
            #("arguments", json.string("")),
          ]),
        ),
      ])
    })
  let arguments =
    range(0, 4)
    |> list.map(fn(i) {
      tool(i, [
        #(
          "function",
          json.object([#("arguments", json.string("{\"code\":\"print(1)\"}"))]),
        ),
      ])
    })
  string_tree.concat([
    chunk(
      json.object([
        #("role", json.string("assistant")),
        #("content", json.string("")),
        #("refusal", json.null()),
      ]),
      json.null(),
    ),
    string_tree.concat(deltas),
    string_tree.concat(opened),
    string_tree.concat(arguments),
    chunk(json.object([]), json.string("tool_calls")),
    string_tree.from_strings([
      "data: ",
      json.to_string(
        json.object([
          #("id", json.string("chatcmpl-abc")),
          #("choices", json.array([], json.string)),
          #(
            "usage",
            json.object([
              #("prompt_tokens", json.int(1200)),
              #("completion_tokens", json.int(count)),
              #(
                "prompt_tokens_details",
                json.object([#("cached_tokens", json.int(1000))]),
              ),
            ]),
          ),
        ]),
      ),
      "\n\ndata: [DONE]\n\n",
    ]),
  ])
}

/// `from` through `to`, ascending.
fn range(from: Int, to: Int) -> List(Int) {
  int.range(to, from - 1, [], list.prepend)
}

fn lorem(i: Int) -> String {
  string.repeat(
    "the quick brown fox "
      <> int.to_string(i)
      <> " jumps over the lazy dog with \"quotes\" and \n newlines. ",
    20,
  )
}

fn tools(count: Int) -> List(types.Tool) {
  range(1, count)
  |> list.map(fn(i) {
    types.Tool(
      "tool_" <> int.to_string(i),
      "Execute Python in your persistent session. Provide code (string); timeout_ms is optional.",
      json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #("code", json.object([#("type", json.string("string"))])),
            #("timeout_ms", json.object([#("type", json.string("integer"))])),
          ]),
        ),
        #("required", json.array(["code"], json.string)),
        #("additionalProperties", json.bool(False)),
      ]),
      False,
    )
  })
}

/// A replayed `tool_1` call as `protocol` would have produced it.
fn replayed_call(protocol: types.Protocol, i: Int) -> types.Input {
  let arguments =
    json.string(json.to_string(json.object([#("code", json.string(lorem(i)))])))
  let item = case protocol {
    types.Responses ->
      json.object([
        #("id", json.string("fc_" <> int.to_string(i))),
        #("type", json.string("function_call")),
        #("status", json.string("completed")),
        #("call_id", json.string("call_" <> int.to_string(i))),
        #("name", json.string("tool_1")),
        #("arguments", arguments),
      ])
    types.ChatCompletions ->
      json.object([
        #("role", json.string("assistant")),
        #("content", json.null()),
        #(
          "tool_calls",
          json.preprocessed_array([
            json.object([
              #("id", json.string("call_" <> int.to_string(i))),
              #("type", json.string("function")),
              #(
                "function",
                json.object([
                  #("name", json.string("tool_1")),
                  #("arguments", arguments),
                ]),
              ),
            ]),
          ]),
        ),
      ])
  }
  let assert Ok(item) =
    json.parse(json.to_string(item), types.replay_decoder(protocol))
  types.Replay(item)
}

/// `inputs` inputs in user, assistant, replayed call, tool output order,
/// with `tool_count` tools and a long system prompt.
fn large_request(
  protocol: types.Protocol,
  inputs: Int,
  tool_count: Int,
) -> types.Request {
  let input =
    range(1, inputs / 4)
    |> list.flat_map(fn(i) {
      [
        types.User(lorem(i)),
        types.Assistant(lorem(i)),
        replayed_call(protocol, i),
        types.ToolOutput("call_" <> int.to_string(i), lorem(i), []),
      ]
    })
  types.Request(
    "gpt-x",
    Some(string.repeat(lorem(0), 200)),
    input,
    tools(tool_count),
    None,
    types.defaults,
  )
}
