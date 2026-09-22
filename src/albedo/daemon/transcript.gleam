import albedo/openai_api/types
import gleam/option.{type Option}

/// A durable transcript item and the daemon time when it was accepted.
/// Legacy rows have no timestamp; unknown time is never reconstructed.
pub type Entry {
  Entry(input: types.Input, timestamp: Option(Int), provider: Option(String))
}
