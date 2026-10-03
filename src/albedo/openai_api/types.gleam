import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Protocol {
  Responses
  ChatCompletions
}

/// The protocol's saved-name form, as profiles and carried proxy state spell it.
pub fn protocol_name(protocol: Protocol) -> String {
  case protocol {
    Responses -> "responses"
    ChatCompletions -> "chat_completions"
  }
}

pub fn protocol_decoder() -> decode.Decoder(Protocol) {
  decode.string
  |> decode.then(fn(name) {
    case name {
      "responses" -> decode.success(Responses)
      "chat_completions" -> decode.success(ChatCompletions)
      _ -> decode.failure(Responses, "protocol")
    }
  })
}

pub type ProviderPolicy {
  OpenAI
  Codex(account_id: String, session_id: String)
}

pub type Client {
  Client(
    protocol: Protocol,
    base_url: String,
    api_key: String,
    timeout_ms: Int,
    max_event_bytes: Int,
    policy: ProviderPolicy,
  )
}

pub const max_image_bytes = 5_242_880

pub const max_image_encoded_bytes = 6_990_508

pub const max_image_edge = 16_384

const max_image_pixels = 40_000_000

/// The images a provider accepts. `max_edge` must hold for every image of
/// every request the session will send, so it is the strictest bound the
/// provider applies as a conversation grows, not the one for a lone image.
/// `max_images` is how many one request may carry, when the provider says.
pub type ImageLimits {
  ImageLimits(max_edge: Int, max_images: Option(Int))
}

/// The bounds albedo itself validates images against, for a provider that
/// states none of its own.
pub const any_images = ImageLimits(max_image_edge, None)

/// Why a provider held to `limits` refuses `image`, or `None` when it takes it.
pub fn image_refusal(limits: ImageLimits, image: Image) -> Option(String) {
  let #(_, width, height, _) = image_meta(image)
  case width > limits.max_edge || height > limits.max_edge {
    False -> None
    True ->
      Some(
        int.to_string(width)
        <> "x"
        <> int.to_string(height)
        <> " image is over this model's "
        <> int.to_string(limits.max_edge)
        <> "px edge limit",
      )
  }
}

/// A bounded, header-validated image. The daemon revalidates decoded bytes before
/// constructing this value; dimensions are display metadata, not decode proof.
pub opaque type Image {
  Image(mime_type: String, data: ImageData, width: Int, height: Int, bytes: Int)
}

/// Where an image's base64 payload lives. A saved image is a content hash into
/// the daemon's image table (see albedo_images.erl): its bytes are read only
/// while a request body is being written, so a loaded transcript holds
/// references rather than every screenshot it ever showed the model.
pub type ImageData {
  InlineData(data: String)
  /// `size` is the payload's byte length; `read` returns exactly those bytes.
  StoredData(hash: String, size: Int, read: fn() -> Result(String, Nil))
}

pub fn image(
  mime_type: String,
  data: String,
  width: Int,
  height: Int,
  bytes: Int,
) -> Result(Image, Error) {
  use _ <- result.try(image_error(
    mime_type,
    string.byte_size(data) > 0
      && string.byte_size(data) <= max_image_encoded_bytes,
    width,
    height,
    bytes,
  ))
  Ok(Image(mime_type, InlineData(data), width, height, bytes))
}

/// The validity contract of `image` and `stored_image`: an allowed MIME type,
/// a nonempty bounded payload, bounded dimensions, and a bounded byte count.
fn image_error(
  mime_type: String,
  payload: Bool,
  width: Int,
  height: Int,
  bytes: Int,
) -> Result(Nil, Error) {
  case
    mime_type == "image/png"
    || mime_type == "image/jpeg"
    || mime_type == "image/webp",
    payload,
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
    True, True, True, True -> Ok(Nil)
  }
}

/// A stored image assembled directly, as compaction frames and loaded
/// transcripts need: same validity contract as `image`, payload read lazily.
pub fn stored_image(
  mime_type: String,
  hash: String,
  size: Int,
  read: fn() -> Result(String, Nil),
  width: Int,
  height: Int,
  bytes: Int,
) -> Result(Image, Error) {
  use _ <- result.try(image_error(
    mime_type,
    size > 0 && size <= max_image_encoded_bytes,
    width,
    height,
    bytes,
  ))
  Ok(Image(mime_type, StoredData(hash, size, read), width, height, bytes))
}

/// MIME type, width, height, and decoded byte count.
pub fn image_meta(image: Image) -> #(String, Int, Int, Int) {
  let Image(mime_type, _, width, height, bytes) = image
  #(mime_type, width, height, bytes)
}

pub fn image_data(image: Image) -> ImageData {
  image.data
}

/// The base64 payload's byte length, known without reading a stored payload.
pub fn image_size(image: Image) -> Int {
  case image.data {
    InlineData(data) -> string.byte_size(data)
    StoredData(size: size, ..) -> size
  }
}

pub type Input {
  User(String)
  UserImage(String, Image)
  Assistant(String)
  ToolOutput(call_id: String, output: String, images: List(Image))
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
    options: Options,
  )
}

/// Generation controls a caller may set; `None` and `[]` keep the provider's
/// default. A provider applies the ones its wire can express.
pub type Options {
  Options(
    temperature: Option(Float),
    top_p: Option(Float),
    stop: List(String),
    tool_choice: Option(ToolChoice),
    parallel_tool_calls: Option(Bool),
    /// Reasoning effort: "minimal", "low", "medium", or "high".
    effort: Option(String),
    format: Option(Format),
  )
}

pub const defaults = Options(None, None, [], None, None, None, None)

pub type ToolChoice {
  AnyTool
  NoTool
  AutoTool
  NamedTool(String)
}

/// Structured output: any JSON object, or one matching `schema`.
pub type Format {
  JsonObject
  JsonSchema(name: String, schema: Json, strict: Bool)
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

/// A decoded JSON value re-encoded, unchanged, for the adapters that decode
/// with `decode.dynamic` and must emit exactly what they read.
@external(erlang, "albedo_openai_json", "encode")
pub fn encode_value(value: Dynamic) -> Json

/// A base64 image payload as a JSON string; a stored payload reads lazily.
@external(erlang, "albedo_openai_json", "base64_string")
pub fn base64_string(data: ImageData) -> Json

pub type ToolCall {
  ToolCall(id: String, name: String, arguments: String)
}

/// Where a request asks its provider to end a cached prefix, and how long
/// that entry should live. Providers that cache on their own get none.
pub type CacheMark {
  CacheMark(through: CacheSpan, ttl_seconds: Int)
}

/// The part of a request a cached prefix runs through, in prefix order.
pub type CacheSpan {
  ToolsSpan
  SystemSpan
  /// Through the projected input at this index.
  InputSpan(index: Int)
}

pub type Usage {
  Usage(
    /// Whole input context: cached reads and new cache writes included.
    input_tokens: Int,
    output_tokens: Int,
    cached_input_tokens: Option(Int),
    cache_creation_tokens: Option(Int),
    /// Cache writes the provider splits by TTL, when it reports the split.
    cache_write_5m_tokens: Option(Int),
    cache_write_1h_tokens: Option(Int),
    /// Tokens the provider names as reasoning, separate from its output
    /// count when it does. Antigravity folds thoughts into output and also
    /// reports the thought count here.
    reasoning_tokens: Option(Int),
  )
}

/// Usage as a provider reports it, with cached reads when it names them.
/// Chat Completions and the Responses API name the same fields differently.
pub fn usage_decoder(
  input_tokens: String,
  output_tokens: String,
  input_tokens_details: String,
  output_tokens_details: String,
) -> decode.Decoder(Usage) {
  use input <- decode.field(input_tokens, decode.int)
  use output <- decode.field(output_tokens, decode.int)
  use details <- decode.optional_field(
    input_tokens_details,
    None,
    decode.optional(cached_tokens_decoder()),
  )
  use reasoning <- decode.optional_field(
    output_tokens_details,
    None,
    decode.optional(reasoning_tokens_decoder()),
  )
  decode.success(Usage(
    input,
    output,
    option.flatten(details),
    None,
    None,
    None,
    option.flatten(reasoning),
  ))
}

fn cached_tokens_decoder() -> decode.Decoder(Option(Int)) {
  decode.optional_field(
    "cached_tokens",
    None,
    decode.optional(decode.int),
    decode.success,
  )
}

fn reasoning_tokens_decoder() -> decode.Decoder(Option(Int)) {
  decode.optional_field(
    "reasoning_tokens",
    None,
    decode.optional(decode.int),
    decode.success,
  )
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
    /// How long the model spent thinking before it answered, when it did:
    /// each spell runs from the event before its thinking to the one after.
    thought_ms: Option(Int),
    /// The exact provider output index for each completed native tool call.
    /// This correlates streamed argument deltas with calls after provider ID
    /// deduplication without relying on list position.
    call_indices: List(#(String, Int)),
  )
}

pub type Event {
  Started(response_id: String)
  TextDelta(output_index: Int, content_index: Int, text: String)
  /// Reasoning text, streamed separately from the user-visible answer.
  ThinkingDelta(text: String)
  /// A fragment of a call's arguments; name is the tool it calls, or empty
  /// until the provider has said.
  ArgumentsDelta(output_index: Int, name: String, text: String)
}

/// The first response id starts the turn; one that changes mid-stream is a
/// broken stream, not a new turn.
pub fn merge_response_id(
  current: Option(String),
  incoming: Option(String),
  changed: String,
) -> Result(#(Option(String), List(Event)), Error) {
  case current, incoming {
    None, Some(id) -> Ok(#(Some(id), [Started(id)]))
    Some(current), Some(incoming) if current != incoming ->
      Error(InvalidEvent(changed))
    _, _ -> Ok(#(current, []))
  }
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
