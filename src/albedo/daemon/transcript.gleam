import albedo/openai_api/types
import gleam/option.{type Option}

/// A durable transcript item and the daemon time when it was accepted.
/// Legacy rows have no timestamp; unknown time is never reconstructed.
/// `thought_ms` is how long the model thought before a response, kept on its
/// first item that shows the thinking.
pub type Entry {
  Entry(
    input: types.Input,
    timestamp: Option(Int),
    provider: Option(String),
    thought_ms: Option(Int),
    source: Option(SourceRef),
  )
}

/// A durable position in one session's append-only transcript. Forks copy
/// payloads into new rows, so their references belong to the new session.
pub type SourceRef {
  SourceRef(session: String, seq: Int)
}

pub type SourcedEntry {
  SourcedEntry(source: SourceRef, entry: Entry)
}

/// A transcript row that swaps every earlier image whose payload hashes to
/// `source` for `image`, a copy scaled to a provider's edge. Readers that
/// only show rows see `note`, a user note that tells the model about it.
pub type ImageFit {
  ImageFit(note: String, source: String, image: types.Image)
}

/// Compaction boundaries include daemon notes, mail, and image fit notes.
pub fn row_class(input: types.Input) -> String {
  case input {
    types.User(_) | types.UserImage(_, _) -> "user"
    _ -> "other"
  }
}
