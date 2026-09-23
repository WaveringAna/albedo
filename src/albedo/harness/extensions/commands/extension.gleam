//// The built-in session commands and the Python kernel's `commands` object.

import albedo/harness/command.{
  type Command, type Context, Argument, Command, Compact, ContextPage,
  ContextSummary, Data, ModelCall, ModelGet, ModelSelect, Refresh, UserCall,
}
import albedo/harness/extension
import albedo/harness/extensions/models/extension as models
import gleam/dict
import gleam/int
import gleam/json
import gleam/option.{None, Some}
import gleam/result

pub fn extension() -> extension.Extension {
  extension.Extension(
    "commands",
    "Session commands shared by the CLI menu and the Python kernel.",
    ["python"],
    [
      extension.CommandPlugin([model(), reload(), context_inspect(), compact()]),
      extension.ToolPlugin("", [], ["commands"], []),
    ],
    fn(_) { Ok(Nil) },
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
    ],
    True,
    False,
    False,
    fn(ctx: Context, caller, args) {
      // A model call is always mid-turn, so it may only read the selection.
      let provider = case dict.get(args, "provider") {
        Ok(value) if value != "" -> Some(value)
        _ -> None
      }
      use value <- result.try(case caller, dict.get(args, "model") {
        ModelCall, Ok(_) ->
          Error(
            "switching models is a user action between turns; ask the user to run /model",
          )
        _, Error(_) ->
          case provider {
            Some(_) -> Error("provider requires model")
            None -> ctx.state(ModelGet)
          }
        UserCall, Ok(model) -> ctx.state(ModelSelect(model, provider))
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
            Data(
              json.object([
                #("reloaded", json.string("models+session")),
                #(
                  "message",
                  json.string(
                    "Models catalog reloaded; extension context, skills catalog, and session commands rescanned.",
                  ),
                ),
              ]),
            ),
          )
        }
      }
    },
  )
}

fn models_reload() -> Result(command.Outcome, String) {
  use _ <- result.try(models.reload())
  Ok(
    Data(
      json.object([
        #("reloaded", json.string("models")),
        #(
          "message",
          json.string(
            "Models catalog reloaded. /model now shows the latest list.",
          ),
        ),
        #("catalog", json.string(models.path())),
      ]),
    ),
  )
}

fn compact() -> Command {
  Command(
    "/compact",
    "Compact this idle session now using its active compaction strategy. The transcript is preserved.",
    [],
    False,
    False,
    False,
    fn(ctx: Context, caller, _args) {
      case caller {
        ModelCall ->
          Error(
            "compaction is a user action between turns; ask the user to run /compact",
          )
        UserCall -> ctx.state(Compact) |> result.map(Data)
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
