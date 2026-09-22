//// The built-in session commands and the kernel's typed `commands` object.
////
//// The command catalog itself is aggregate: every enabled extension
//// contributes commands, and the dispatch routes and prompt block are
//// composed from all of them. This extension adds the session introspection
//// commands and the Python bindings the model calls.

import albedo/harness/command.{
  type Command, type Context, Argument, Command, Data, ModelCall, UserCall,
}
import albedo/harness/extension
import gleam/dict
import gleam/result

pub fn extension() -> extension.Extension {
  extension.Extension(
    "commands",
    "Session commands shared by the CLI menu and the Python kernel.",
    ["python"],
    [
      extension.CommandPlugin([model(), context_inspect()]),
      extension.ToolPlugin("", [], ["commands"], []),
    ],
    fn(_) { Ok(Nil) },
  )
}

fn model() -> Command {
  Command(
    "/model",
    "Show this session's provider and model, or switch the model. Switching is a user action and needs an idle session.",
    [
      Argument(
        "model",
        "model id to switch to (user only); omit to show the current selection",
        False,
      ),
      Argument(
        "provider",
        "configured provider name, needed only when switching providers",
        False,
      ),
    ],
    True,
    False,
    fn(ctx: Context, caller, args) {
      // A model call is always mid-turn, and switching mid-turn is refused for
      // users too, so the model can read the selection but never switch it.
      use value <- result.try(case caller, dict.get(args, "model") {
        ModelCall, Ok(_) ->
          Error(
            "switching models is a user action between turns; ask the user to run /model",
          )
        _, Error(_) -> ctx.state("model.get", dict.new())
        UserCall, Ok(model) ->
          ctx.state(
            "model.select",
            dict.from_list([
              #("model", model),
              #("provider", dict.get(args, "provider") |> result.unwrap("")),
            ]),
          )
      })
      Ok(Data(value))
    },
  )
}

fn context_inspect() -> Command {
  Command(
    "/context",
    "Read the prepared model request: one summary, or a bounded page of one section.",
    [
      Argument("section", "section id as listed by the summary", False),
      Argument("page", "0-based page number within the section", False),
    ],
    True,
    False,
    fn(ctx: Context, _caller, args) {
      use value <- result.try(case dict.get(args, "section") {
        Error(_) -> ctx.state("context.summary", dict.new())
        Ok(section) ->
          ctx.state(
            "context.page",
            dict.from_list([
              #("section", section),
              #("page", dict.get(args, "page") |> result.unwrap("0")),
            ]),
          )
      })
      Ok(Data(value))
    },
  )
}
