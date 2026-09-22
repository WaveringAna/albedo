//// Command dispatch, raw parsing, and catalog agreement.

import albedo/daemon/store
import albedo/harness/command.{
  type Argument, type Command, Argument, Command, Data, ModelCall, Turn,
  UserCall,
}
import albedo/harness/commands
import albedo/harness/extension
import gleam/dict
import gleam/json
import gleam/result
import gleeunit/should

fn stub_state(op: String, args: dict.Dict(String, String)) {
  case op {
    "submit" ->
      Ok(
        json.object([
          #(
            "display",
            json.string(dict.get(args, "display") |> result.unwrap("")),
          ),
        ]),
      )
    "model.get" -> Ok(json.string("selection"))
    _ -> Error("unexpected state operation: " <> op)
  }
}

fn stub_context() {
  let assert Ok(ledger) = store.start(":memory:", "")
  command.Context("test", ledger, stub_state)
}

fn demo() {
  Command(
    "/demo",
    "Demo",
    [Argument("arguments", "freeform", False)],
    True,
    True,
    fn(_context, caller, args) {
      let arguments = dict.get(args, "arguments") |> result.unwrap("")
      case caller {
        UserCall -> Ok(Turn("/demo " <> arguments, "turn " <> arguments))
        ModelCall -> Ok(Data(json.string("data " <> arguments)))
      }
    },
  )
}

fn locked() {
  Command(
    "/locked",
    "User only",
    [],
    False,
    False,
    fn(_context, _caller, _args) { Ok(Data(json.string("locked"))) },
  )
}

fn placeholder(arguments: List(Argument)) -> Command {
  Command("/x", "", arguments, True, False, fn(_, _, _) {
    Ok(Data(json.string("")))
  })
}

pub fn parse_arguments_keeps_inner_spacing_exact_test() {
  command.parse_arguments(
    placeholder([
      Argument("arguments", "", False),
    ]),
    "  one  two  ",
  )
  |> should.equal(Ok(dict.from_list([#("arguments", "one  two")])))
}

pub fn raw_invocation_maps_tokens_positionally_test() {
  let command =
    placeholder([
      Argument("model", "", False),
      Argument("provider", "", False),
    ])
  command.parse_arguments(command, "gpt-5  acme labs")
  |> should.equal(
    Ok(
      dict.from_list([
        #("model", "gpt-5"),
        #("provider", "acme labs"),
      ]),
    ),
  )
  command.parse_arguments(command, "gpt-5")
  |> should.equal(Ok(dict.from_list([#("model", "gpt-5")])))
  command.parse_arguments(command, "")
  |> should.equal(Ok(dict.new()))
}

pub fn missing_required_arguments_report_usage_test() {
  let command = placeholder([Argument("model", "", True)])
  command.parse_arguments(command, "  ")
  |> should.equal(Error("missing argument <model>"))
  command.check_arguments(command, dict.new())
  |> should.equal(Error("missing argument <model>; usage: /x <model>"))
  command.check_arguments(command, dict.from_list([#("surprise", "x")]))
  |> should.equal(Error("unknown argument <surprise>; usage: /x <model>"))
}

pub fn method_names_mangle_to_python_identifiers_test() {
  command.method_name("/model") |> should.equal("model")
  command.method_name("/fix-lint") |> should.equal("fix_lint")
  command.method_name("/skill:model") |> should.equal("skill_model")
}

pub fn model_calls_cannot_run_user_only_commands_or_submit_turns_test() {
  let commands = [demo(), locked()]
  command.dispatch(
    commands,
    stub_context(),
    ModelCall,
    "kernel",
    "/locked",
    dict.new(),
  )
  |> should.equal(Error("/locked is not callable from the model"))
  // A run that misbehaves and returns a turn in model mode is refused, and the
  // turn is never submitted.
  let sneaky =
    Command("/sneaky", "", [], True, True, fn(_, _, _) {
      Ok(Turn("display", "text"))
    })
  command.dispatch(
    [sneaky],
    stub_context(),
    ModelCall,
    "kernel",
    "/sneaky",
    dict.new(),
  )
  |> should.be_error
}

pub fn model_switching_is_refused_from_the_model_test() {
  let values = extension.commands([commands.extension()])
  // The read form answers for any caller...
  let assert Ok(Data(reading)) =
    command.dispatch(
      values,
      stub_context(),
      UserCall,
      "c",
      "/model",
      dict.new(),
    )
  reading |> should.equal(json.string("selection"))
  let assert Ok(Data(_)) =
    command.dispatch(
      values,
      stub_context(),
      ModelCall,
      "kernel",
      "/model",
      dict.new(),
    )
  // ...while the switch form is a user action, refused from the model.
  command.dispatch(
    values,
    stub_context(),
    ModelCall,
    "kernel",
    "/model",
    dict.from_list([#("model", "next")]),
  )
  |> should.equal(Error(
    "switching models is a user action between turns; ask the user to run /model",
  ))
}

pub fn user_turn_commands_submit_through_state_test() {
  let assert Ok(Turn(display, text)) =
    command.dispatch(
      [demo()],
      stub_context(),
      UserCall,
      "client-1",
      "/demo",
      dict.from_list([#("arguments", "one  two")]),
    )
  display |> should.equal("/demo one  two")
  text |> should.equal("turn one  two")
  let assert Ok(Data(value)) =
    command.dispatch(
      [demo()],
      stub_context(),
      ModelCall,
      "kernel",
      "/demo",
      dict.from_list([#("arguments", "one  two")]),
    )
  value |> should.equal(json.string("data one  two"))
}
