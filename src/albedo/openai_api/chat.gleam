import albedo/openai_api/reasoning
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
      case decode.run(value, decode.at(["error", "message"], decode.string)) {
        Ok(message) -> Error(types.ProviderError(message))
        Error(_) -> {
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
    decode.optional(usage_decoder()),
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
  use fields <- decode.then(decode.dict(decode.string, decode.dynamic))
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
      use content <- decode.optional_field(
        "content",
        None,
        decode.optional(decode.string),
      )
      use refusal <- decode.optional_field(
        "refusal",
        None,
        decode.optional(decode.string),
      )
      use reasoning <- decode.then(reasoning.decoder())
      use tools <- decode.optional_field(
        "tool_calls",
        [],
        decode.optional(decode.list(tool_fragment_decoder()))
          |> decode.map(fn(value) { option_list(value) }),
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

fn tool_fragment_decoder() -> decode.Decoder(ToolFragment) {
  use index <- decode.field("index", decode.int)
  use id <- decode.optional_field("id", None, decode.optional(decode.string))
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
  case kind, function {
    Some(kind), _ if kind != "function" ->
      decode.failure(ToolFragment(index, id, None, None), "function tool call")
    _, Some(#(name, arguments)) ->
      decode.success(ToolFragment(index, id, name, arguments))
    _, None -> decode.success(ToolFragment(index, id, None, None))
  }
}

fn function_fragment_decoder() -> decode.Decoder(
  #(Option(String), Option(String)),
) {
  use name <- decode.optional_field(
    "name",
    None,
    decode.optional(decode.string),
  )
  use arguments <- decode.optional_field(
    "arguments",
    None,
    decode.optional(decode.string),
  )
  decode.success(#(name, arguments))
}

fn usage_decoder() -> decode.Decoder(types.Usage) {
  use input <- decode.field("prompt_tokens", decode.int)
  use output <- decode.field("completion_tokens", decode.int)
  use details <- decode.optional_field(
    "prompt_tokens_details",
    None,
    decode.optional(cached_tokens_decoder()),
  )
  decode.success(types.Usage(input, output, option.flatten(details)))
}

fn cached_tokens_decoder() -> decode.Decoder(Option(Int)) {
  use cached <- decode.optional_field(
    "cached_tokens",
    None,
    decode.optional(decode.int),
  )
  decode.success(cached)
}

fn option_list(value: Option(List(a))) -> List(a) {
  case value {
    Some(value) -> value
    None -> []
  }
}

fn unsupported_field(fields: Dict(String, dynamic.Dynamic)) -> Option(String) {
  case
    fields
    |> dict.to_list
    |> list.find_map(fn(entry) {
      case entry.0 {
        "role"
        | "content"
        | "refusal"
        | "reasoning_content"
        | "reasoning"
        | "reasoning_details"
        | "tool_calls" -> Error(Nil)
        field ->
          case semantically_empty(entry.1) {
            True -> Error(Nil)
            False -> Ok(field)
          }
      }
    })
  {
    Ok(field) -> Some(field)
    Error(_) -> None
  }
}

fn semantically_empty(value: dynamic.Dynamic) -> Bool {
  case decode.run(value, decode.optional(decode.dynamic)) {
    Ok(None) -> True
    _ ->
      case decode.run(value, decode.string) {
        Ok("") -> True
        _ ->
          case decode.run(value, decode.list(decode.dynamic)) {
            Ok([]) -> True
            _ ->
              case
                decode.run(value, decode.dict(decode.dynamic, decode.dynamic))
              {
                Ok(fields) -> dict.is_empty(fields)
                _ -> False
              }
          }
      }
  }
}

fn apply_chunk(
  state: State,
  chunk: Chunk,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  let State(id, content, refusal, reasoning, tools, usage, finish, terminal) =
    state
  let Chunk(chunk_id, choices, chunk_usage) = chunk
  use #(id, started) <- result.try(merge_id(id, chunk_id))
  use #(content, refusal, reasoning, tools, finish, delta_events) <- result.try(
    case choices {
      [] -> Ok(#(content, refusal, reasoning, tools, finish, []))
      [Choice(0, _, _)] if finish != None ->
        Error(types.InvalidEvent("chat choice after finish reason"))
      [Choice(0, delta, choice_finish)] -> {
        let Delta(_, content_delta, refusal_delta, reasoning_delta, fragments) =
          delta
        use reasoning <- result.try(reasoning.append(reasoning, reasoning_delta))
        use tools <- result.try(merge_fragments(tools, fragments))
        use finish <- result.try(merge_finish(finish, choice_finish))
        Ok(#(
          append_optional(content, content_delta),
          append_optional(refusal, refusal_delta),
          reasoning,
          tools,
          finish,
          delta_events(
            content_delta,
            reasoning.stream_text(reasoning_delta),
            fragments,
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
  let usage = case chunk_usage {
    Some(value) -> Some(value)
    None -> usage
  }
  Ok(#(
    State(id, content, refusal, reasoning, tools, usage, finish, terminal),
    list.append(started, delta_events),
    None,
  ))
}

fn delta_events(
  content: Option(String),
  reasoning: String,
  tools: List(ToolFragment),
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
    tools
    |> list.filter_map(fn(fragment) {
      let ToolFragment(index, _, _, arguments) = fragment
      case arguments {
        Some(arguments) -> Ok(types.ArgumentsDelta(index, arguments))
        None -> Error(Nil)
      }
    })
  list.append(thinking, list.append(text, arguments))
}

fn merge_id(
  current: Option(String),
  incoming: Option(String),
) -> Result(#(Option(String), List(types.Event)), types.Error) {
  case current, incoming {
    None, Some(id) -> Ok(#(Some(id), [types.Started(id)]))
    Some(current), Some(incoming) if current != incoming ->
      Error(types.InvalidEvent("chat completion response id changed"))
    _, _ -> Ok(#(current, []))
  }
}

fn append_optional(
  accumulated: Option(List(String)),
  fragment: Option(String),
) -> Option(List(String)) {
  case accumulated, fragment {
    value, None -> value
    None, Some(value) -> Some([value])
    Some(values), Some(fragment) -> Some([fragment, ..values])
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
    let existing = dict.get(tools, index)
    let builder = case existing {
      Error(_) -> ToolBuilder(None, None, [])
      Ok(builder) -> builder
    }
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
  let State(id, content, refusal, reasoning, builders, usage, finish, _) = state
  use finish <- result.try(case finish {
    Some(value) -> Ok(value)
    None -> Error(types.InvalidEvent("[DONE] before chat finish reason"))
  })
  let expose_tools = finish == types.ToolCalls
  use tools <- result.try(case expose_tools {
    True -> complete_tools(builders)
    False -> Ok([])
  })
  let replay_tools = case expose_tools {
    True -> tools
    False -> []
  }
  let message =
    assistant_message(
      option.map(content, flatten),
      option.map(refusal, flatten),
      reasoning,
      replay_tools,
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
      id,
      None,
      None,
      reasoning.new(),
      dict.new(),
      usage,
      Some(finish),
      True,
    ),
    [],
    Some(types.Turn(id, output, tools, usage, finish)),
  ))
}

fn complete_tools(
  builders: Dict(Int, ToolBuilder),
) -> Result(List(types.ToolCall), types.Error) {
  builders
  |> dict.to_list
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  |> list.try_map(fn(entry) {
    let ToolBuilder(id, name, arguments) = entry.1
    case id, name {
      Some(id), Some(name) if id != "" && name != "" ->
        Ok(types.ToolCall(id, name, flatten(arguments)))
      _, _ ->
        Error(types.InvalidEvent(
          "incomplete tool call at index " <> int.to_string(entry.0),
        ))
    }
  })
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
  let fields = put_optional(fields, "refusal", refusal)
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

fn put_optional(
  fields: List(#(dynamic.Dynamic, dynamic.Dynamic)),
  key: String,
  value: Option(String),
) -> List(#(dynamic.Dynamic, dynamic.Dynamic)) {
  case value {
    Some(value) -> [#(dynamic.string(key), dynamic.string(value)), ..fields]
    None -> fields
  }
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
