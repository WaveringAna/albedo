import albedo/openai_api/reasoning
import albedo/openai_api/replay
import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub opaque type State {
  State(
    response_id: Option(String),
    content: Option(List(String)),
    refusal: Option(List(String)),
    reasoning: reasoning.State,
    tools: Dict(Int, ToolBuilder),
    usage: Option(types.Usage),
    finish: Option(types.Finish),
    terminal: Bool,
  )
}

type ToolBuilder {
  ToolBuilder(id: Option(String), name: Option(String), arguments: List(String))
}

type Chunk {
  Chunk(id: Option(String), choices: List(Choice), usage: Option(types.Usage))
}

type Choice {
  Choice(index: Int, delta: Delta, finish: Option(String))
}

type Delta {
  Delta(
    role: Option(String),
    content: Option(String),
    refusal: Option(String),
    reasoning: reasoning.Delta,
    tools: List(ToolFragment),
  )
}

type ToolFragment {
  ToolFragment(
    index: Int,
    id: Option(String),
    name: Option(String),
    arguments: Option(String),
  )
}

pub fn new() -> State {
  State(None, None, None, reasoning.new(), dict.new(), None, None, False)
}

pub fn feed(
  state: State,
  data: String,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  let State(_, _, _, _, _, _, _, terminal) = state
  case terminal, data {
    True, _ -> Error(types.InvalidEvent("chat chunk after [DONE]"))
    False, "[DONE]" -> finish(state)
    False, _ -> {
      use value <- result.try(
        json.parse(data, decode.dynamic)
        |> result.map_error(fn(error) {
          types.InvalidEvent("invalid chat JSON: " <> string.inspect(error))
        }),
      )
      let error_decoder =
        decode.optionally_at(
          ["error", "message"],
          None,
          decode.map(decode.string, Some),
        )
      case decode.run(value, error_decoder) {
        Ok(Some(message)) -> Error(types.ProviderError(message))
        _ -> {
          use chunk <- result.try(
            decode.run(value, chunk_decoder())
            |> result.map_error(fn(error) {
              types.InvalidEvent(
                "invalid chat completion chunk: " <> string.inspect(error),
              )
            }),
          )
          apply_chunk(state, chunk)
        }
      }
    }
  }
}

fn chunk_decoder() -> decode.Decoder(Chunk) {
  use id <- decode.optional_field("id", None, decode.optional(decode.string))
  use choices <- decode.field("choices", decode.list(choice_decoder()))
  use usage <- decode.optional_field(
    "usage",
    None,
    decode.optional(types.usage_decoder(
      "prompt_tokens",
      "completion_tokens",
      "prompt_tokens_details",
      "completion_tokens_details",
    )),
  )
  decode.success(Chunk(id, choices, usage))
}

fn choice_decoder() -> decode.Decoder(Choice) {
  use index <- decode.field("index", decode.int)
  use delta <- decode.field("delta", delta_decoder())
  use finish <- decode.optional_field(
    "finish_reason",
    None,
    decode.optional(decode.string),
  )
  decode.success(Choice(index, delta, finish))
}

fn delta_decoder() -> decode.Decoder(Delta) {
  use fields <- decode.then(decode.new_primitive_decoder("Dict", object_fields))
  case unsupported_field(fields) {
    Some(field) ->
      decode.failure(
        Delta(None, None, None, reasoning.empty_delta(), []),
        "supported chat delta (unsupported nonempty field " <> field <> ")",
      )
    None -> {
      use role <- decode.optional_field(
        "role",
        None,
        decode.optional(decode.string),
      )
      use content <- decode.optional_field("content", None, non_empty_string())
      use refusal <- decode.optional_field("refusal", None, non_empty_string())
      use reasoning <- decode.then(reasoning.decoder())
      use tools <- decode.optional_field(
        "tool_calls",
        [],
        decode.optional(decode.list(tool_fragment_decoder()))
          |> decode.map(option.unwrap(_, [])),
      )
      case role {
        Some(role) if role != "assistant" ->
          decode.failure(
            Delta(Some(role), content, refusal, reasoning, tools),
            "assistant role",
          )
        _ -> decode.success(Delta(role, content, refusal, reasoning, tools))
      }
    }
  }
}

@external(erlang, "albedo_openai_json", "object_fields")
fn object_fields(
  value: dynamic.Dynamic,
) -> Result(Dict(String, dynamic.Dynamic), Dict(String, dynamic.Dynamic))

fn non_empty_string() -> decode.Decoder(Option(String)) {
  decode.optional(decode.string)
  |> decode.map(fn(value) {
    case value {
      Some("") -> None
      other -> other
    }
  })
}

fn tool_fragment_decoder() -> decode.Decoder(ToolFragment) {
  use index <- decode.field("index", decode.int)
  use id <- decode.optional_field("id", None, non_empty_string())
  use kind <- decode.optional_field(
    "type",
    None,
    decode.optional(decode.string),
  )
  use function <- decode.optional_field(
    "function",
    None,
    decode.optional(function_fragment_decoder()),
  )
  let #(name, arguments) = option.unwrap(function, #(None, None))
  case kind {
    Some(kind) if kind != "function" ->
      decode.failure(ToolFragment(index, id, None, None), "function tool call")
    _ -> decode.success(ToolFragment(index, id, name, arguments))
  }
}

fn function_fragment_decoder() -> decode.Decoder(
  #(Option(String), Option(String)),
) {
  use name <- decode.optional_field("name", None, non_empty_string())
  use arguments <- decode.optional_field("arguments", None, non_empty_string())
  decode.success(#(name, arguments))
}

fn unsupported_field(fields: Dict(String, dynamic.Dynamic)) -> Option(String) {
  fields
  |> dict.to_list
  |> list.find_map(fn(entry) {
    case
      list.contains(replay.portable_fields, entry.0)
      || semantically_empty(entry.1)
    {
      True -> Error(Nil)
      False -> Ok(entry.0)
    }
  })
  |> option.from_result
}

@external(erlang, "albedo_openai_json", "semantically_empty")
fn semantically_empty(value: dynamic.Dynamic) -> Bool

fn apply_chunk(
  state: State,
  chunk: Chunk,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  let Chunk(chunk_id, choices, chunk_usage) = chunk
  use #(id, started) <- result.try(types.merge_response_id(
    state.response_id,
    chunk_id,
    "chat completion response id changed",
  ))
  use #(content, refusal, reasoning, tools, finish, delta_events) <- result.try(
    case choices {
      [] ->
        Ok(
          #(
            state.content,
            state.refusal,
            state.reasoning,
            state.tools,
            state.finish,
            [],
          ),
        )
      [Choice(0, _, _)] if state.finish != None ->
        Error(types.InvalidEvent("chat choice after finish reason"))
      [Choice(0, delta, choice_finish)] -> {
        let Delta(_, content_delta, refusal_delta, reasoning_delta, fragments) =
          delta
        use reasoning <- result.try(reasoning.append(
          state.reasoning,
          reasoning_delta,
        ))
        use tools <- result.try(merge_fragments(state.tools, fragments))
        use finish <- result.try(merge_finish(state.finish, choice_finish))
        Ok(#(
          append_optional(state.content, content_delta),
          append_optional(state.refusal, refusal_delta),
          reasoning,
          tools,
          finish,
          delta_events(
            content_delta,
            reasoning.stream_text(reasoning_delta),
            fragments,
            tools,
          ),
        ))
      }
      [Choice(index, _, _)] ->
        Error(types.Unsupported(
          "chat completion choice index "
          <> int.to_string(index)
          <> "; request n=1 and only index 0 is supported",
        ))
      _ -> Error(types.Unsupported("multiple chat completion choices"))
    },
  )
  Ok(#(
    State(
      ..state,
      response_id: id,
      content:,
      refusal:,
      reasoning:,
      tools:,
      finish:,
      usage: option.or(chunk_usage, state.usage),
    ),
    list.append(started, delta_events),
    None,
  ))
}

fn delta_events(
  content: Option(String),
  reasoning: String,
  fragments: List(ToolFragment),
  tools: Dict(Int, ToolBuilder),
) -> List(types.Event) {
  let thinking = case reasoning {
    "" -> []
    text -> [types.ThinkingDelta(text)]
  }
  let text = case content {
    Some(text) -> [types.TextDelta(0, 0, text)]
    None -> []
  }
  let arguments =
    fragments
    |> list.filter_map(fn(fragment) {
      case fragment.arguments {
        Some(arguments) -> {
          // the name so far: it arrives with the call's first fragments
          let name = case dict.get(tools, fragment.index) {
            Ok(ToolBuilder(_, Some(name), _)) -> name
            _ -> ""
          }
          Ok(types.ArgumentsDelta(fragment.index, name, arguments))
        }
        None -> Error(Nil)
      }
    })
  list.flatten([thinking, text, arguments])
}

fn append_optional(
  accumulated: Option(List(String)),
  fragment: Option(String),
) -> Option(List(String)) {
  case fragment {
    None -> accumulated
    Some(f) -> Some([f, ..option.unwrap(accumulated, [])])
  }
}

fn flatten(fragments: List(String)) -> String {
  fragments |> list.reverse |> string.concat
}

fn merge_finish(
  current: Option(types.Finish),
  incoming: Option(String),
) -> Result(Option(types.Finish), types.Error) {
  case current, incoming {
    current, None -> Ok(current)
    None, Some(reason) -> Ok(Some(finish_reason(reason)))
    Some(_), Some(_) ->
      Error(types.InvalidEvent("duplicate chat finish reason"))
  }
}

fn finish_reason(reason: String) -> types.Finish {
  case reason {
    "stop" -> types.Complete
    "tool_calls" -> types.ToolCalls
    "length" -> types.LengthLimit
    "content_filter" -> types.ContentFiltered
    other -> types.OtherFinish(other)
  }
}

fn merge_fragments(
  tools: Dict(Int, ToolBuilder),
  fragments: List(ToolFragment),
) -> Result(Dict(Int, ToolBuilder), types.Error) {
  list.try_fold(fragments, tools, fn(tools, fragment) {
    let ToolFragment(index, id, name, arguments) = fragment
    use _ <- result.try(case index < 0 {
      True -> Error(types.InvalidEvent("negative tool call index"))
      False -> Ok(Nil)
    })
    let builder =
      dict.get(tools, index)
      |> result.unwrap(ToolBuilder(None, None, []))
    let ToolBuilder(old_id, old_name, old_arguments) = builder
    use id <- result.try(merge_identity(old_id, id, "tool call id"))
    let name = case old_name, name {
      value, None -> value
      None, value -> value
      Some(prefix), Some(suffix) -> Some(prefix <> suffix)
    }
    let arguments = case arguments {
      Some(fragment) -> [fragment, ..old_arguments]
      None -> old_arguments
    }
    Ok(dict.insert(tools, index, ToolBuilder(id, name, arguments)))
  })
}

fn merge_identity(
  current: Option(String),
  incoming: Option(String),
  label: String,
) -> Result(Option(String), types.Error) {
  case current, incoming {
    None, value -> Ok(value)
    value, None -> Ok(value)
    Some(current), Some(incoming) if current == incoming -> Ok(Some(current))
    Some(_), Some(_) -> Error(types.InvalidEvent(label <> " changed"))
  }
}

fn finish(
  state: State,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  use finish <- result.try(
    state.finish
    |> option.to_result(types.InvalidEvent("[DONE] before chat finish reason")),
  )
  use tools <- result.try(case finish {
    types.ToolCalls -> complete_tools(state.tools)
    _ -> Ok([])
  })
  let message =
    assistant_message(
      option.map(state.content, flatten),
      option.map(state.refusal, flatten),
      state.reasoning,
      tools,
    )
  use output <- result.try(
    decode.run(message, types.replay_decoder(types.ChatCompletions))
    |> result.map(fn(item) { [item] })
    |> result.map_error(fn(error) {
      types.InvalidEvent(
        "invalid accumulated assistant message: " <> string.inspect(error),
      )
    }),
  )
  Ok(#(
    State(
      ..state,
      content: None,
      refusal: None,
      reasoning: reasoning.new(),
      tools: dict.new(),
      finish: Some(finish),
      terminal: True,
    ),
    [],
    Some(types.Turn(state.response_id, output, tools, state.usage, finish, None)),
  ))
}

fn complete_tools(
  builders: Dict(Int, ToolBuilder),
) -> Result(List(types.ToolCall), types.Error) {
  builders
  |> dict.to_list
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  |> list.try_fold(#([], []), fn(acc, entry) {
    let #(seen, calls) = acc
    let ToolBuilder(id, name, arguments) = entry.1
    case id, name {
      Some(id), Some(name) if id != "" && name != "" -> {
        let unique_id = case list.contains(seen, id) {
          True -> id <> "_" <> int.to_string(entry.0)
          False -> id
        }
        Ok(
          #([id, ..seen], [
            types.ToolCall(unique_id, name, flatten(arguments)),
            ..calls
          ]),
        )
      }
      _, _ ->
        Error(types.InvalidEvent(
          "incomplete tool call at index " <> int.to_string(entry.0),
        ))
    }
  })
  |> result.map(fn(acc) { list.reverse(acc.1) })
}

fn assistant_message(
  content: Option(String),
  refusal: Option(String),
  reasoning: reasoning.State,
  tools: List(types.ToolCall),
) -> dynamic.Dynamic {
  let fields = [
    #(dynamic.string("role"), dynamic.string("assistant")),
    #(dynamic.string("content"), case content {
      Some(content) -> dynamic.string(content)
      None -> json_null()
    }),
  ]
  let fields = case refusal {
    Some(refusal) -> [
      #(dynamic.string("refusal"), dynamic.string(refusal)),
      ..fields
    ]
    None -> fields
  }
  let fields = list.append(reasoning.fields(reasoning), fields)
  let fields = case tools {
    [] -> fields
    tools -> [
      #(
        dynamic.string("tool_calls"),
        dynamic.list(list.map(tools, tool_dynamic)),
      ),
      ..fields
    ]
  }
  dynamic.properties(fields)
}

fn tool_dynamic(call: types.ToolCall) -> dynamic.Dynamic {
  let types.ToolCall(id, name, arguments) = call
  dynamic.properties([
    #(dynamic.string("id"), dynamic.string(id)),
    #(dynamic.string("type"), dynamic.string("function")),
    #(
      dynamic.string("function"),
      dynamic.properties([
        #(dynamic.string("name"), dynamic.string(name)),
        #(dynamic.string("arguments"), dynamic.string(arguments)),
      ]),
    ),
  ])
}

@external(erlang, "albedo_openai_json", "null")
fn json_null() -> dynamic.Dynamic
