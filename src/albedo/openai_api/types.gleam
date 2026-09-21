import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/option.{type Option}

pub type Protocol {
  Responses
  ChatCompletions
}

pub type Client {
  Client(
    protocol: Protocol,
    base_url: String,
    api_key: String,
    timeout_ms: Int,
    max_event_bytes: Int,
  )
}

pub type Input {
  User(String)
  Assistant(String)
  ToolOutput(call_id: String, output: String)
  Replay(ReplayItem)
}

pub type Tool {
  Tool(name: String, description: String, parameters: Json, strict: Bool)
}

pub type Request {
  Request(
    model: String,
    instructions: Option(String),
    input: List(Input),
    tools: List(Tool),
    max_output_tokens: Option(Int),
  )
}

/// An unmodified provider output object, including opaque replay fields.
pub opaque type ReplayItem {
  ReplayItem(protocol: Protocol, value: Dynamic)
}

pub fn replay_protocol(item: ReplayItem) -> Protocol {
  item.protocol
}

pub fn replay_decoder(protocol: Protocol) -> decode.Decoder(ReplayItem) {
  use value <- decode.then(decode.dynamic)
  case protocol {
    Responses -> {
      use _ <- decode.field("type", decode.string)
      decode.success(ReplayItem(protocol, value))
    }
    ChatCompletions -> {
      use role <- decode.field("role", decode.string)
      case role {
        "assistant" -> decode.success(ReplayItem(protocol, value))
        _ -> decode.failure(ReplayItem(protocol, value), "assistant message")
      }
    }
  }
}

pub fn replay_json(item: ReplayItem) -> Json {
  encode_value(item.value)
}

/// Decode a saved provider item with a caller-selected typed view.
pub fn inspect_item(
  item: ReplayItem,
  decoder: decode.Decoder(a),
) -> Result(a, List(decode.DecodeError)) {
  decode.run(item.value, decoder)
}

@external(erlang, "albedo_openai_json", "encode")
fn encode_value(value: Dynamic) -> Json

pub type ToolCall {
  ToolCall(id: String, name: String, arguments: String)
}

pub type Usage {
  Usage(input_tokens: Int, output_tokens: Int, cached_input_tokens: Option(Int))
}

pub type Finish {
  Complete
  ToolCalls
  LengthLimit
  ContentFiltered
  OtherFinish(String)
}

pub type Turn {
  Turn(
    response_id: Option(String),
    output: List(ReplayItem),
    tool_calls: List(ToolCall),
    usage: Option(Usage),
    finish: Finish,
  )
}

pub type Event {
  Started(response_id: String)
  TextDelta(output_index: Int, content_index: Int, text: String)
  /// Reasoning text, streamed separately from the user-visible answer.
  ThinkingDelta(text: String)
  ArgumentsDelta(output_index: Int, text: String)
}

pub type Control {
  Continue
  Stop
}

pub type Error {
  InvalidRequest(String)
  HttpError(status: Int, body: String)
  ConnectionError(String)
  Timeout
  Cancelled
  InvalidEvent(String)
  EventTooLarge
  UnexpectedEnd
  ProviderError(message: String)
  Unsupported(String)
}
