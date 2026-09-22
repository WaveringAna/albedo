import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/string

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

pub const max_image_bytes = 5_242_880

pub const max_image_edge = 16_384

pub const max_image_pixels = 40_000_000

/// A bounded, header-validated image. The daemon revalidates decoded bytes before
/// constructing this value; dimensions are display metadata, not decode proof.
pub opaque type Image {
  Image(mime_type: String, data: String, width: Int, height: Int, bytes: Int)
}

pub fn image(
  mime_type: String,
  data: String,
  width: Int,
  height: Int,
  bytes: Int,
) -> Result(Image, Error) {
  case
    mime_type == "image/png"
    || mime_type == "image/jpeg"
    || mime_type == "image/webp",
    string.byte_size(data) > 0 && string.byte_size(data) <= 6_990_508,
    width > 0
    && height > 0
    && width <= max_image_edge
    && height <= max_image_edge
    && width * height <= max_image_pixels,
    bytes > 0 && bytes <= max_image_bytes
  {
    False, _, _, _ -> Error(InvalidRequest("image must be PNG, JPEG, or WebP"))
    _, False, _, _ -> Error(InvalidRequest("invalid image payload size"))
    _, _, False, _ -> Error(InvalidRequest("invalid image dimensions"))
    _, _, _, False -> Error(InvalidRequest("invalid decoded image size"))
    True, True, True, True -> Ok(Image(mime_type, data, width, height, bytes))
  }
}

pub fn image_parts(image: Image) -> #(String, String, Int, Int, Int) {
  let Image(mime_type, data, width, height, bytes) = image
  #(mime_type, data, width, height, bytes)
}

pub type Input {
  User(String)
  UserImage(String, Image)
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
