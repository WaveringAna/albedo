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

pub fn efforts_for_model(
  state: session_state.State(message),
  model: String,
) -> List(String) {
  model_efforts(state.host, state.home, state.info.provider, model)
}

pub fn model_efforts(
  host: runtime.Runtime,
  home: String,
  provider: String,
  model: String,
) -> List(String) {
  let endpoint = case configuration.named(home, provider) {
    Ok(configured) if configured.extension == "codex" ->
      "https://chatgpt.com/backend-api"
    _ -> ""
  }
  case runtime.global(host) {
    Ok(extensions) ->
      case extension.model_info(extensions, model, endpoint) {
        option.Some(info) -> info.efforts
        option.None -> []
      }
    Error(_) -> []
  }
}

pub fn read_effort(
  state: session_state.State(message),
) -> Result(json.Json, String) {
  let efforts = efforts_for_model(state, state.info.model)
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

pub fn change_effort(
  state: session_state.State(message),
  level: String,
) -> #(session_state.State(message), Result(json.Json, String)) {
  case turn.running(state.activity) {
    option.Some(_) -> #(
      state,
      Error("switching effort requires an idle session"),
    )
    option.None -> {
      let efforts = efforts_for_model(state, state.info.model)
      case efforts {
        [] -> #(
          state,
          Error(
            "model " <> state.info.model <> " does not support reasoning effort",
          ),
        )
        _ -> {
          let trimmed = string.trim(string.lowercase(level))
          case list.contains(efforts, trimmed) {
            False -> #(
              state,
              Error(
                "unsupported reasoning effort: "
                <> trimmed
                <> "; available: "
                <> string.join(efforts, ", "),
              ),
            )
            True ->
              case
                conversation.set_effort(
                  runtime.ledger(state.host),
                  state.info.id,
                  option.Some(trimmed),
                )
              {
                Error(error) -> #(state, Error(error))
                Ok(_) -> #(
                  session_state.State(
                    ..state,
                    info: conversation.Info(
                      ..state.info,
                      effort: option.Some(trimmed),
                    ),
                  ),
                  Ok(
                    json.object([
                      #("effort", json.string(trimmed)),
                      #(
                        "message",
                        json.string("reasoning effort set to " <> trimmed),
                      ),
                    ]),
                  ),
                )
              }
          }
        }
      }
    }
  }
}

/// Validate history against the new provider before persisting the selection.
pub fn select(
  state: session_state.State(message),
  model: String,
  provider_name: option.Option(String),
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
            let efforts = model_efforts(state.host, state.home, provider, model)
            let new_effort = case state.info.effort {
              option.Some(current) ->
                case list.contains(efforts, current) {
                  True -> option.Some(current)
                  False -> extension.default_effort(efforts)
                }
              option.None -> extension.default_effort(efforts)
            }
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
