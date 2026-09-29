import albedo/harness/cache_fade
import albedo/openai_api/types
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

/// The latest provider completion metadata for a session.
///
/// `tokens: None` means that the completed response omitted usage. It is kept
/// as a real completion so clients can clear measurements from an older turn.
/// `cache` says how its cached count fades once the session goes quiet.
pub type Metadata {
  Metadata(
    model: String,
    recorded_at: Int,
    tokens: Option(Tokens),
    cache: Option(cache_fade.Fade),
  )
}

pub type Tokens {
  Tokens(
    prompt_tokens: Int,
    completion_tokens: Int,
    cached_prompt_tokens: Option(Int),
    cache_creation_tokens: Option(Int),
    cache_write_5m_tokens: Option(Int),
    cache_write_1h_tokens: Option(Int),
    reasoning_tokens: Option(Int),
  )
}

pub fn from_completion(
  model: String,
  provider_usage: Option(types.Usage),
  recorded_at: Int,
  cache: Option(cache_fade.Fade),
) -> Metadata {
  let tokens = case provider_usage {
    Some(types.Usage(
      prompt,
      completion,
      cached,
      creation,
      write_5m,
      write_1h,
      reasoning,
    )) ->
      Some(Tokens(
        prompt,
        completion,
        cached,
        creation,
        write_5m,
        write_1h,
        reasoning,
      ))
    None -> None
  }
  Metadata(model, recorded_at, tokens, cache)
}

/// Encodes a usage completion event. Unreported token counts are omitted so
/// clients distinguish unknown from zero.
pub fn event(metadata: Metadata) -> String {
  let Metadata(model, recorded_at, tokens, cache) = metadata
  let token_fields = case tokens {
    Some(Tokens(
      prompt,
      completion,
      cached,
      creation,
      write_5m,
      write_1h,
      reasoning,
    )) ->
      [
        #("promptTokens", json.int(prompt)),
        #("completionTokens", json.int(completion)),
        #("totalTokens", json.int(prompt + completion)),
      ]
      |> opt_field("cacheCreationTokens", creation)
      |> opt_field("cachedPromptTokens", cached)
      |> opt_field("cacheWrite5mTokens", write_5m)
      |> opt_field("cacheWrite1hTokens", write_1h)
      |> opt_field("reasoningTokens", reasoning)
    None -> []
  }
  let cache_fields = case cache {
    Some(fade) -> [#("cacheFade", cache_fade.steps_json(fade))]
    None -> []
  }
  json.object([
    #("type", json.string("usage")),
    #("model", json.string(model)),
    #("recordedAt", json.int(recorded_at)),
    ..list.append(token_fields, cache_fields)
  ])
  |> json.to_string
}

fn opt_field(
  fields: List(#(String, json.Json)),
  key: String,
  value: Option(Int),
) -> List(#(String, json.Json)) {
  case value {
    Some(val) -> [#(key, json.int(val)), ..fields]
    None -> fields
  }
}

type TimeUnit {
  Millisecond
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: TimeUnit) -> Int

pub fn now() -> Int {
  system_time(Millisecond)
}
