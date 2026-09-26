//// Provider selection, reasoning effort, and on-demand upstream binding.

import albedo/daemon/configuration
import albedo/daemon/conversation
import albedo/daemon/session_history
import albedo/daemon/session_state
import albedo/daemon/turn
import albedo/harness/extension
import albedo/harness/runtime
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

/// The endpoint a profile's reasoning efforts are looked up under. Codex
/// subscriptions read OpenAI's metadata through the ChatGPT endpoint. Other
/// extensions ignore the endpoint.
pub fn effort_endpoint(extension: String) -> String {
  case extension {
    "codex" -> "https://chatgpt.com/backend-api"
    _ -> ""
  }
}

/// The reasoning efforts a session on `provider` accepts for `model`.
pub fn model_efforts(
  host: runtime.Runtime,
  home: String,
  provider: String,
  model: String,
) -> List(String) {
  let extension = case configuration.named(home, provider) {
    Ok(configured) -> configured.extension
    Error(_) -> ""
  }
  runtime.model_efforts(host, model, effort_endpoint(extension))
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

/// The level as `model` on `provider` spells it, or why the model refuses it.
fn supported_effort(
  state: session_state.State(message),
  provider: String,
  model: String,
  level: String,
) -> Result(String, String) {
  let level = string.trim(string.lowercase(level))
  case model_efforts(state.host, state.home, provider, model) {
    [] -> Error("model " <> model <> " does not support reasoning effort")
    efforts ->
      case list.contains(efforts, level) {
        True -> Ok(level)
        False ->
          Error(
            "unsupported reasoning effort: "
            <> level
            <> "; available: "
            <> string.join(efforts, ", "),
          )
      }
  }
}

pub fn change_effort(
  state: session_state.State(message),
  level: String,
) -> #(session_state.State(message), Result(json.Json, String)) {
  let changed = {
    use _ <- result.try(case turn.running(state.activity) {
      option.Some(_) -> Error("switching effort requires an idle session")
      option.None -> Ok(Nil)
    })
    use level <- result.try(supported_effort(
      state,
      state.info.provider,
      state.info.model,
      level,
    ))
    conversation.set_effort(
      runtime.ledger(state.host),
      state.info.id,
      option.Some(level),
    )
    |> result.replace(level)
  }
  case changed {
    Error(error) -> #(state, Error(error))
    Ok(level) -> #(
      session_state.State(
        ..state,
        info: conversation.Info(..state.info, effort: option.Some(level)),
      ),
      Ok(
        json.object([
          #("effort", json.string(level)),
          #("message", json.string("reasoning effort set to " <> level)),
        ]),
      ),
    )
  }
}

/// Validate history against the new provider before persisting the selection.
pub fn select(
  state: session_state.State(message),
  model: String,
  provider_name: option.Option(String),
  effort: option.Option(String),
) -> #(session_state.State(message), Result(Nil, String)) {
  case
    turn.running(state.activity) == option.None
    && string.trim(model) != ""
    && string.byte_size(model) <= 512
    && !string.contains(model, "\r")
    && !string.contains(model, "\n")
  {
    False -> #(state, Error("model must be nonempty and session idle"))
    True ->
      case session_history.ensure_history(state) {
        Error(error) -> #(state, Error(error))
        Ok(state) -> {
          let selected = {
            use #(provider, protocol) <- result.try(case provider_name {
              option.None -> Ok(#(state.info.provider, state.info.protocol))
              option.Some(name) ->
                configuration.named(state.home, name)
                |> result.map(fn(configured) {
                  #(configured.name, configured.protocol)
                })
            })
            // An asked-for level must fit the new model. Otherwise the
            // current one carries over when it fits.
            use new_effort <- result.try(case effort {
              option.Some(level) ->
                supported_effort(state, provider, model, level)
                |> result.map(option.Some)
              option.None -> {
                let efforts =
                  model_efforts(state.host, state.home, provider, model)
                Ok(case state.info.effort {
                  option.Some(current) ->
                    case list.contains(efforts, current) {
                      True -> option.Some(current)
                      False -> extension.default_effort(efforts)
                    }
                  option.None -> extension.default_effort(efforts)
                })
              }
            })
            use _ <- result.try(
              session_history.projected_for(state.history, provider, protocol)
              |> result.replace(Nil)
              |> result.map_error(fn(error) {
                "cannot switch provider: " <> error
              }),
            )
            use _ <- result.try(configuration.select_default(
              state.home,
              provider,
              model,
            ))
            use _ <- result.try(conversation.set_configuration(
              runtime.ledger(state.host),
              state.info.id,
              provider,
              model,
              protocol,
              new_effort,
            ))
            Ok(#(provider, protocol, new_effort))
          }
          case selected {
            Error(error) -> #(state, Error(error))
            Ok(#(provider, protocol, effort)) -> #(
              session_state.State(
                ..state,
                history: option.map(
                  state.history,
                  session_history.tag_unknown_provider(_, state.info.provider),
                ),
                info: conversation.Info(
                  ..state.info,
                  provider: provider,
                  model: model,
                  protocol: protocol,
                  effort: effort,
                ),
                context: session_state.unprepared(),
              ),
              Ok(Nil),
            )
          }
        }
      }
  }
}
