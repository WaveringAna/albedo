import albedo/openai_api/types
import gleam/json
import gleam/option.{type Option, None, Some}

/// The latest provider completion metadata for a session.
///
/// `tokens: None` means that the completed response omitted usage. It is kept
/// as a real completion so clients can clear measurements from an older turn.
pub type Metadata {
  Metadata(model: String, recorded_at: Int, tokens: Option(Tokens))
}

pub type Tokens {
  Tokens(
    prompt_tokens: Int,
    completion_tokens: Int,
    cached_prompt_tokens: Option(Int),
    cache_creation_tokens: Option(Int),
  )
}

pub fn from_completion(
  model: String,
  provider_usage: Option(types.Usage),
  recorded_at: Int,
) -> Metadata {
  let tokens = case provider_usage {
    Some(types.Usage(prompt, completion, cached, creation)) ->
      Some(Tokens(prompt, completion, cached, creation))
    None -> None
  }
  Metadata(model, recorded_at, tokens)
}

/// Encodes a usage completion event. Unreported token counts are omitted so
/// clients distinguish unknown from zero.
pub fn event(metadata: Metadata) -> String {
  let Metadata(model, recorded_at, tokens) = metadata
  let token_fields = case tokens {
    Some(Tokens(prompt, completion, cached, creation)) -> {
      let fields = [
        #("promptTokens", json.int(prompt)),
        #("completionTokens", json.int(completion)),
        #("totalTokens", json.int(prompt + completion)),
      ]
      let fields = case creation {
        Some(value) -> [#("cacheCreationTokens", json.int(value)), ..fields]
        None -> fields
      }
      case cached {
        Some(value) -> [#("cachedPromptTokens", json.int(value)), ..fields]
        None -> fields
      }
    }
    None -> []
  }
  json.object([
    #("type", json.string("usage")),
    #("model", json.string(model)),
    #("recordedAt", json.int(recorded_at)),
    ..token_fields
  ])
  |> json.to_string
}

type TimeUnit {
  Millisecond
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: TimeUnit) -> Int

pub fn now() -> Int {
  system_time(Millisecond)
}
