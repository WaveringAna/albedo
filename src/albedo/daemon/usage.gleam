import albedo/clock
import albedo/harness/cache_fade
import albedo/openai_api/types
import gleam/int
import gleam/option.{type Option, None, Some}

/// The latest provider completion metadata for a session.
///
/// `tokens: None` means that the completed response omitted usage. It is kept
/// as a real completion so clients can clear measurements from an older turn.
/// `cache` says how its cached count fades once the session goes quiet.
/// `elapsed_ms` is the span of the call that produced the record, None when no
/// call did; a re-emitted record keeps its call's span.
pub type Metadata {
  Metadata(
    model: String,
    recorded_at: Int,
    tokens: Option(Tokens),
    cache: Option(cache_fade.Fade),
    elapsed_ms: Option(Int),
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
  elapsed_ms: Option(Int),
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
  Metadata(model, recorded_at, tokens, cache, elapsed_ms)
}

/// Output tokens per second over the call's span, or None when the call has no
/// usage or took no measurable time.
pub fn tokens_per_second(metadata: Metadata) -> Option(Float) {
  case metadata.tokens, metadata.elapsed_ms {
    Some(Tokens(completion_tokens: tokens, ..)), Some(elapsed) if elapsed > 0 ->
      Some(int.to_float(tokens) *. 1000.0 /. int.to_float(elapsed))
    _, _ -> None
  }
}

pub fn now() -> Int {
  clock.system_ms()
}
