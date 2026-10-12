//// Provider selection, reasoning effort, and on-demand upstream binding.

import albedo/daemon/configuration
import albedo/daemon/conversation
import albedo/daemon/session_history
import albedo/daemon/session_state
import albedo/harness/extension
import albedo/harness/runtime
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string

pub fn configured_client(
  state: session_state.State(message),
) -> Result(#(session_state.State(message), extension.Upstream), String) {
  use provider <- result.try(case state.info.provider {
    "" -> {
      use provider <- result.try(configuration.legacy(state.home))
      use _ <- result.try(conversation.assign_session_provider(
        runtime.ledger(state.host),
        state.info.id,
        provider.name,
      ))
      Ok(provider)
    }
    name -> configuration.named(state.home, name)
  })
  let state = case state.info.provider {
    "" ->
      session_state.State(
        ..state,
        history: option.map(state.history, session_history.tag_unknown_provider(
          _,
          provider.name,
        )),
        info: conversation.Info(..state.info, provider: provider.name),
      )
    _ -> state
  }
  use client <- result.try(runtime.upstream(
    state.host,
    state.info.id,
    state.home,
    provider.name,
    provider.extension,
    state.info.model,
    state.info.protocol,
    state.info.effort,
  ))
  Ok(#(state, client))
}

/// The endpoint a profile is configured with, if any.
pub fn profile_endpoint(
  home: String,
  provider: String,
) -> option.Option(String) {
  configuration.settings(
    home,
    provider,
    decode.optional_field("baseUrl", "", decode.string, decode.success),
  )
  |> result.unwrap("")
  |> extension.clean_endpoint
}

/// The reasoning efforts a session on `provider` accepts for `model`.
pub fn model_efforts(
  host: runtime.Runtime,
  home: String,
  provider: String,
  model: String,
) -> List(String) {
  let endpoint = profile_endpoint(home, provider)
  runtime.model_efforts(host, model, endpoint)
}

pub fn read_effort(
  state: session_state.State(message),
) -> Result(json.Json, String) {
  let efforts =
    model_efforts(state.host, state.home, state.info.provider, state.info.model)
  case efforts {
    [] ->
      Error(
        "model " <> state.info.model <> " does not support reasoning effort",
      )
    _ -> {
      let current = state.info.effort
      let available = string.join(efforts, ", ")
      let message = case current {
        option.Some(level) ->
          "reasoning effort is " <> level <> " (available: " <> available <> ")"
        option.None ->
          "reasoning effort is not set (available: " <> available <> ")"
      }
      Ok(
        json.object([
          #("effort", json.nullable(current, json.string)),
          #("available", json.array(efforts, json.string)),
          #("message", json.string(message)),
        ]),
      )
    }
  }
}

/// Keep a supported current level, then a supported profile default, then the
/// model default. Explicitly requested levels are validated by the caller.
pub fn resolve_effort(
  efforts: List(String),
  current: option.Option(String),
  configured: option.Option(String),
) -> option.Option(String) {
  case
    [current, configured]
    |> list.filter_map(option.to_result(_, Nil))
    |> list.find(list.contains(efforts, _))
  {
    Ok(level) -> option.Some(level)
    Error(_) -> extension.default_effort(efforts)
  }
}
