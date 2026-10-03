import albedo/harness/cache_fade
import albedo/openai_api/types
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

type TimeUnit {
  Millisecond
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: TimeUnit) -> Int

pub fn now() -> Int {
  system_time(Millisecond)
}
