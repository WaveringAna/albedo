//// The built-in session commands and the Python kernel's `commands` object.

import albedo/harness/command.{
  type Command, type Context, Argument, Command, Compact, ContextPage,
  ContextSummary, Data, EffortGet, EffortSelect, ModelCall, ModelGet,
  ModelSelect, Refresh, UserCall,
}
import albedo/harness/extension
import albedo/harness/extensions/models/extension as models
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result

pub fn extension() -> extension.Extension {
  extension.Extension(
    "commands",
    "Session commands shared by the CLI menu and the Python kernel.",
    ["python"],
    [
      extension.CommandPlugin([
        model(),
        reload(),
        context_inspect(),
        compact(),
        raise_cap(),
        effort(),
      ]),
      extension.ToolPlugin("", [], ["commands"], []),
    ],
    extension.no_initialise,
  )
}

fn user_action(what: String, command: String) -> String {
  what <> " is a user action between turns; ask the user to run " <> command
}

fn effort() -> Command {
  Command(
    "/effort",
    "Show this session's reasoning effort, or switch it to an available level (user only).",
    [
      Argument(
        "level",
        "reasoning effort level; omit to show the current setting",
        False,
        ["low", "medium", "high"],
      ),
    ],
    True,
    False,
    False,
    fn(ctx: Context, caller, args) {
      use value <- result.try(case caller, dict.get(args, "level") {
        ModelCall, Ok(_) -> Error(user_action("switching effort", "/effort"))
        _, Error(_) -> ctx.state(EffortGet)
        UserCall, Ok(level) -> ctx.state(EffortSelect(level))
      })
      Ok(Data(value))
    },
  )
}

fn model() -> Command {
  Command(
    "/model",
    "Show this session's provider and model, or switch it and make the selection the default for new sessions. Switching is a user action and needs an idle session.",
    [
      Argument(
        "model",
        "model id to switch to (user only); omit to show the current selection",
        False,
        [],
      ),
      Argument(
        "provider",
        "configured provider name, needed only when switching providers",
        False,
        [],
      ),
      Argument(
        "effort",
        "reasoning effort for the new model; omit to keep the current level when the model supports it",
        False,
        [],
      ),
    ],
    True,
    False,
    False,
    fn(ctx: Context, caller, args) {
      // A model call is always mid-turn, so it may only read the selection.
      let given = fn(name) {
        case dict.get(args, name) {
          Ok(value) if value != "" -> Some(value)
          _ -> None
        }
      }
      let provider = given("provider")
      use value <- result.try(case caller, dict.get(args, "model") {
        ModelCall, Ok(_) -> Error(user_action("switching models", "/model"))
        _, Error(_) ->
          case provider, given("effort") {
            None, None -> ctx.state(ModelGet)
            Some(_), _ -> Error("provider requires model")
            None, Some(_) ->
              Error("effort requires model; /effort changes it alone")
          }
        UserCall, Ok(model) ->
          ctx.state(ModelSelect(model, provider, given("effort")))
      })
      Ok(Data(value))
    },
  )
}

fn reload() -> Command {
  Command(
    "/reload",
    "Reload cached runtime data: the models.dev catalog, the session's skills catalog and extension context, or both. A session reload rescans in place — the kernel, its Python namespace, and the prompt cache keep running.",
    [
      Argument(
        "target",
        "models, session (skills, context, and commands), or omit for both",
        False,
        ["models", "session"],
      ),
    ],
    False,
    False,
    False,
    fn(ctx: Context, _caller, args) {
      case dict.get(args, "target") {
        Ok("models") -> models_reload()
        Ok("session") -> ctx.state(Refresh) |> result.map(Data)
        Ok(target) ->
          Error(
            "unknown reload target " <> target <> "; available: models, session",
          )
        Error(_) -> {
          use _ <- result.try(models.reload())
          use _ <- result.try(ctx.state(Refresh))
          Ok(
            reloaded(
              "models+session",
              "Models catalog reloaded; extension context, skills catalog, and session commands rescanned.",
              [],
            ),
          )
        }
      }
    },
  )
}

fn reloaded(
  scope: String,
  message: String,
  extra: List(#(String, json.Json)),
) -> command.Outcome {
  Data(
    json.object([
      #("reloaded", json.string(scope)),
      #("message", json.string(message)),
      ..extra
    ]),
  )
}

fn models_reload() -> Result(command.Outcome, String) {
  use _ <- result.try(models.reload())
  Ok(
    reloaded(
      "models",
      "Models catalog reloaded. /model now shows the latest list.",
      [#("catalog", json.string(models.path()))],
    ),
  )
}

fn compact() -> Command {
  Command(
    "/compact",
    "Compact this idle session now using its active compaction strategy, or switch the session to the named strategy first (rolling for a text summary before changing to a model without image input). The transcript is preserved.",
    [
      Argument(
        "strategy",
        "compaction strategy to switch this session to; omit to keep the active one",
        False,
        ["snapcompact", "rolling", "lcm"],
      ),
    ],
    False,
    False,
    False,
    fn(ctx: Context, caller, args) {
      case caller {
        ModelCall -> Error(user_action("compaction", "/compact"))
        UserCall ->
          ctx.state(Compact(option.from_result(dict.get(args, "strategy"))))
          |> result.map(Data)
      }
    },
  )
}

/// Raises a model's context cap to the provider's maximum window, or restores
/// its default window. The choice is global: every session on the model uses
/// it from its next request.
fn raise_cap() -> Command {
  Command(
    "/raise-cap",
    "Raise the model's context window to the provider's maximum, or restore its default. Models degrade over long contexts, so the default window stays unless you raise it. Applies to every session on the model from its next request.",
    [
      Argument(
        "state",
        "on raises the cap, off restores the default window; omit to toggle",
        False,
        ["on", "off"],
      ),
      Argument("model", "model id; omit for this session's model", False, []),
    ],
    False,
    False,
    False,
    fn(ctx: Context, caller, args) {
      case caller {
        ModelCall ->
          Error(
            "the context cap is the user's choice; ask the user to run /raise-cap",
          )
        UserCall -> {
          use model <- result.try(case dict.get(args, "model") {
            Ok(model) -> Ok(model)
            Error(_) -> {
              use value <- result.try(ctx.state(ModelGet))
              json.parse(
                json.to_string(value),
                decode.field("model", decode.string, decode.success),
              )
              |> result.replace_error("could not read this session's model")
            }
          })
          let raised = list.contains(extension.raised_caps(), model)
          use raise <- result.try(case dict.get(args, "state") {
            Ok("on") -> Ok(True)
            Ok("off") -> Ok(False)
            Ok(other) -> Error("state must be on or off, not " <> other)
            Error(_) -> Ok(!raised)
          })
          use _ <- result.try(extension.raise_cap(model, raise))
          let message = case raise {
            True ->
              "Raised the context cap for "
              <> model
              <> ": sessions on it use the provider's maximum window from their next request. /context shows the window."
            False -> "Restored the default context window for " <> model <> "."
          }
          Ok(
            Data(
              json.object([
                #("model", json.string(model)),
                #("raised", json.bool(raise)),
                #("message", json.string(message)),
              ]),
            ),
          )
        }
      }
    },
  )
}

fn context_inspect() -> Command {
  Command(
    "/context",
    "Read the prepared model request: one summary, or a bounded page of one section.",
    [
      Argument("section", "section id as listed by the summary", False, []),
      Argument("page", "0-based page number within the section", False, []),
    ],
    True,
    False,
    False,
    fn(ctx: Context, _caller, args) {
      use value <- result.try(case dict.get(args, "section") {
        Error(_) -> ctx.state(ContextSummary)
        Ok(section) -> {
          use page <- result.try(
            dict.get(args, "page")
            |> result.unwrap("0")
            |> int.parse
            |> result.replace_error("page must be a number"),
          )
          ctx.state(ContextPage(section, page))
        }
      })
      Ok(Data(value))
    },
  )
}
