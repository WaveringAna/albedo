//// The built-in session commands and the Python kernel's `commands` object.

import albedo/harness/command.{
  type Command, type Context, Argument, Command, ContextPage, ContextSummary,
  Data, ModelCall, ModelGet, ModelSelect, UserCall,
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
      extension.CommandPlugin([model(), reload(), context_inspect()]),
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
    "Reload cached runtime data. The first supported target is models.",
    [Argument("target", "reload the models.dev catalog", True, ["models"])],
    False,
    False,
    fn(_ctx, _caller, args) {
      case dict.get(args, "target") {
        Ok("models") -> {
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
        Ok(target) ->
          Error("unknown reload target " <> target <> "; available: models")
        Error(_) -> Error("reload target is required")
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
