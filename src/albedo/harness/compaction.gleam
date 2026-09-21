//// Optional request-history projection, not a transcript rewrite.
//// No strategy ships here: selection is None until an owner supplies one.

import albedo/daemon/store
import albedo/harness/python/kernel
import albedo/openai_api/types

pub type Context {
  Context(
    store: store.Store,
    session: String,
    kernel: kernel.Kernel,
    model: String,
  )
}

/// Receives chronological history before each model request. Implementations
/// own their summaries/state and must preserve valid tool call/result pairs.
/// Failure stops the turn; the full durable transcript is never replaced.
pub type Strategy {
  Strategy(
    name: String,
    prepare: fn(Context, List(types.Input)) -> Result(List(types.Input), String),
  )
}
