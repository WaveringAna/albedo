//// Existing session and transcript column additions, before session recovery.

import albedo/daemon/store
import gleam/result
import sqlight

pub fn apply(db: sqlight.Connection) -> Result(Nil, String) {
  use _ <- result.try(
    store.add_columns(db, "sessions", [
      #("provider", "TEXT"),
      #("title", "TEXT"),
      #("activity_seq", "INTEGER"),
      #("last_assistant_at", "INTEGER"),
      #("usage_model", "TEXT"),
      #("usage_recorded_at", "INTEGER"),
      #("usage_prompt_tokens", "INTEGER"),
      #("usage_completion_tokens", "INTEGER"),
      #("usage_cached_prompt_tokens", "INTEGER"),
      #("usage_cache_creation_tokens", "INTEGER"),
      #("usage_cache_write_5m_tokens", "INTEGER"),
      #("usage_cache_write_1h_tokens", "INTEGER"),
      #("usage_reasoning_tokens", "INTEGER"),
      #("usage_cache", "TEXT"),
      #("effort", "TEXT"),
      #("pinned_instructions", "TEXT"),
      #("pinned_context", "BLOB"),
      #("pinned_head", "INTEGER"),
      #("name", "TEXT"),
    ]),
  )
  store.add_columns(db, "transcript", [
    #("timestamp", "INTEGER"),
    #("provider", "TEXT"),
    #("thought_ms", "INTEGER"),
    #("row_class", "TEXT CHECK(row_class IN ('user','image_fit','other'))"),
  ])
}
