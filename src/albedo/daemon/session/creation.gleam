//// Session creation choices shared by admission and the registry.
//// HTTP syntax validation belongs to http_api; resolution and effects belong
//// to the registry. This module owns canonical intent and rejection policy.

import albedo/daemon/operations
import albedo/daemon/store
import albedo/harness/location
import gleam/json
import gleam/option.{type Option, None}
import gleam/string

pub type Intent {
  NewSession(
    workspace: String,
    name: Option(String),
    provider_profile: Option(String),
    model: Option(String),
    effort: Option(String),
  )
  ForkSession(
    source_session_id: String,
    checkpoint_id: String,
    name: Option(String),
  )
  ChildSession(
    parent_id: String,
    address: String,
    name: String,
    initial_input_id: String,
    task: String,
    model: Option(String),
    effort: Option(String),
  )
}

/// Canonical submitted intent, before resolving defaults. Field order and
/// explicit nulls also determine retained operation fingerprints, so changing
/// this representation affects retries of previously recorded decisions.
pub fn encode(intent: Intent) -> json.Json {
  json.object(case intent {
    NewSession(workspace, name, provider, model, effort) -> [
      #("kind", json.string("new")),
      #("workspace", json.string(workspace)),
      #("name", json.nullable(name, json.string)),
      #("provider_profile", json.nullable(provider, json.string)),
      #("model", json.nullable(model, json.string)),
      #("effort", json.nullable(effort, json.string)),
    ]
    ForkSession(source, checkpoint, name) -> [
      #("kind", json.string("fork")),
      #("source_session_id", json.string(source)),
      #("checkpoint_id", json.string(checkpoint)),
      #("name", json.nullable(name, json.string)),
    ]
    ChildSession(parent, address, name, input_id, task, model, effort) -> [
      #("kind", json.string("child")),
      #("parent_id", json.string(parent)),
      #("address", json.string(address)),
      #("name", json.string(name)),
      #("initial_input_id", json.string(input_id)),
      #("task", json.string(task)),
      #("model", json.nullable(model, json.string)),
      #("effort", json.nullable(effort, json.string)),
    ]
  })
}

/// Initial child tasks share message admission identity with HTTP inputs.
pub fn task_input(
  id: String,
  session: String,
  task: String,
) -> operations.Request {
  let submitted = operations.message_intent(task, [], []) |> json.to_string
  operations.Request(
    id,
    operations.fingerprint(submitted),
    "message",
    session,
    None,
  )
}

/// Dependency failures remain retryable; durable refusals retain their decision.
pub fn reject(
  ledger: store.Store,
  operation: operations.Request,
  failure: operations.Rejection,
) -> Result(operations.Receipt, String) {
  case failure.status >= 500 {
    True -> Error(failure.detail)
    False -> operations.reject(ledger, operation, failure)
  }
}

pub fn workspace_failure(failure: location.Failure) -> operations.Rejection {
  case failure {
    location.Invalid(detail) ->
      operations.Rejection(400, "workspace_invalid", detail)
    location.Unavailable(detail) ->
      operations.Rejection(503, "workspace_unavailable", detail)
  }
}

/// Creation failures also define the refusal projected by the HTTP adapter.
pub fn failure(code: String) -> operations.Rejection {
  case code {
    "operation_conflict" ->
      operations.Rejection(
        409,
        "id_conflict",
        "resource identity belongs to another intent",
      )
    "input_conflict" ->
      operations.Rejection(
        409,
        code,
        "input identity belongs to another intent",
      )
    "operation_expired" ->
      operations.Rejection(
        410,
        "identity_expired",
        "resource identity is outside its admission window",
      )
    "operation_invalid" ->
      operations.Rejection(
        400,
        "identity_invalid",
        "resource identity must be a current UUIDv7",
      )
    "operation_future" ->
      operations.Rejection(
        400,
        "identity_future",
        "resource identity is beyond the allowed future clock window",
      )
    "session not found" ->
      operations.Rejection(404, "session_not_found", "session was not found")
    "session_exists" ->
      operations.Rejection(
        412,
        "session_exists",
        "session resource already exists",
      )
    "session_deleted" ->
      operations.Rejection(
        410,
        "session_deleted",
        "session resource was deleted",
      )
    "name must be 1-32 characters of a-z, 0-9, '-' or '_'"
    | "'parent' is reserved"
    | "'self' is reserved"
    | "'all' is reserved" ->
      operations.Rejection(400, "child_address_invalid", code)
    "expected a model"
    | "unsupported effort"
    | "saved profile effort is unsupported by this model" ->
      operations.Rejection(400, "model_selection_invalid", code)
    "provider is not configured; run /login"
    | "provider configuration is invalid; run /login"
    | "active provider is not configured; run /login"
    | "session provider is not configured; run /login" ->
      operations.Rejection(409, "provider_unconfigured", code)
    "provider_profile_unknown" ->
      operations.Rejection(400, code, "provider profile was not found")
    "model is available from multiple providers; use provider/model" ->
      operations.Rejection(409, "model_ambiguous", code)
    "checkpoint not found" ->
      operations.Rejection(404, "checkpoint_not_found", code)
    "invalid branch checkpoint or session id" ->
      operations.Rejection(400, "checkpoint_invalid", code)
    "duplicate tool call id before checkpoint"
    | "checkpoint contains a tool result without its call" ->
      operations.Rejection(409, "checkpoint_invalid", code)
    "deletion_in_progress" ->
      operations.Rejection(409, code, "session deletion is in progress")
    _ ->
      case string.starts_with(code, "model is not available from provider ") {
        True -> operations.Rejection(409, "model_unavailable", code)
        False ->
          case
            string.starts_with(code, "a child named '")
            && string.ends_with(code, "' already exists")
          {
            True ->
              operations.Rejection(
                409,
                "child_address_conflict",
                operations.scalar_prefix(code, 4096),
              )
            False ->
              operations.Rejection(
                503,
                "request_unavailable",
                operations.scalar_prefix(code, 4096),
              )
          }
      }
  }
}
