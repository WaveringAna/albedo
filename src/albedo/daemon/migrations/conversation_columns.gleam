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
      #("usage_cache_miss_tokens", "INTEGER"),
      #("usage_cache_drift_tokens", "INTEGER"),
      #("effort", "TEXT"),
      #("pinned_instructions", "TEXT"),
      #("pinned_context", "BLOB"),
      #("pinned_head", "INTEGER"),
      #("known_instructions", "TEXT"),
      #("known_context", "BLOB"),
      #("known_tools", "TEXT"),
      #("prepared_head", "INTEGER"),
      #("name", "TEXT"),
      #("input_order", "INTEGER NOT NULL DEFAULT 0"),
      #("created_at", "INTEGER"),
      #("activity_at", "INTEGER"),
      #("config_revision", "INTEGER NOT NULL DEFAULT 0"),
      #("family_revision", "INTEGER NOT NULL DEFAULT 0"),
      #("deletion_id", "TEXT"),
      #("context_window", "INTEGER"),
      #("role", "TEXT NOT NULL DEFAULT ''"),
      #("started_by", "TEXT"),
      #("peer_closed_at", "INTEGER"),
    ]),
  )
  use _ <- result.try(
    store.add_columns(db, "provider_requests", [
      #("run_id", "TEXT"),
      #("input_chain", "TEXT"),
      #("first_event_ms", "INTEGER"),
      #("streamed_events", "INTEGER"),
      #("streamed_thinking_bytes", "INTEGER"),
      #("streamed_output_bytes", "INTEGER"),
      #("first_byte_ms", "INTEGER"),
      #("total_tokens", "INTEGER"),
      #("response_id", "TEXT"),
      #("model_version", "TEXT"),
      #("trace_id", "TEXT"),
      #("effort", "TEXT"),
    ]),
  )
  store.add_columns(db, "transcript", [
    #("timestamp", "INTEGER"),
    #("provider", "TEXT"),
    #("thought_ms", "INTEGER"),
    #("turn_id", "TEXT"),
    #(
      "calls_indexed",
      "INTEGER NOT NULL DEFAULT 0 CHECK(calls_indexed IN (0,1))",
    ),
    #("row_class", "TEXT CHECK(row_class IN ('user','image_fit','other'))"),
  ])
}
