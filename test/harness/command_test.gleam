//// Command dispatch, raw parsing, naming, and catalog agreement.

import albedo/harness/command.{
  type Argument, type Command, Argument, Command, Data, ModelCall, Turn,
  UserCall,
}
import albedo/harness/extension
import albedo/harness/extensions/commands/extension as commands
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/result
import gleeunit/should

fn stub_state(op: command.StateOp) -> Result(json.Json, String) {
  case op {
    command.Submit(display, _, _) ->
      Ok(json.object([#("display", json.string(display))]))
    command.ModelGet -> Ok(json.string("selection"))
    _ -> Error("unexpected state operation")
  }
}

fn stub_context() {
  command.Context(stub_state)
}

fn demo() {
  Command(
    "/demo",
    "Demo",
    [Argument("arguments", "freeform", False, [])],
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
      Argument("arguments", "", False, []),
    ]),
    "  one  two  ",
  )
  |> should.equal(Ok(dict.from_list([#("arguments", "one  two")])))
}

pub fn raw_invocation_maps_tokens_positionally_test() {
  let command =
    placeholder([
      Argument("model", "", False, []),
      Argument("provider", "", False, []),
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
  let command = placeholder([Argument("model", "", True, [])])
  command.parse_arguments(command, "  ")
  |> should.equal(Error("missing argument <model>"))
  command.check_arguments(command, dict.new())
  |> should.equal(Error("missing argument <model>; usage: /x <model>"))
  command.check_arguments(command, dict.from_list([#("surprise", "x")]))
  |> should.equal(Error("unknown argument <surprise>; usage: /x <model>"))
}

pub fn method_names_are_mintable_and_collision_free_test() {
  command.method_name("/model") |> should.equal("model")
  command.method_name("/fix-lint") |> should.equal("fix_lint")
  command.method_name("/skill:model") |> should.equal("skill_model")
  // A whole catalog disambiguates reserved names and collisions.
  let methods =
    command.method_names([
      demo(),
      Command("/skill:model", "", [], True, False, fn(_, _, _) {
        Ok(Data(json.string("")))
      }),
      Command("/skill-model", "", [], True, False, fn(_, _, _) {
        Ok(Data(json.string("")))
      }),
      Command("/catalog", "", [], True, False, fn(_, _, _) {
        Ok(Data(json.string("")))
      }),
      Command("/__init__", "", [], True, False, fn(_, _, _) {
        Ok(Data(json.string("")))
      }),
    ])
  dict.get(methods, "/skill:model")
  |> should.equal(Ok("skill_model"))
  dict.get(methods, "/skill-model")
  |> should.equal(Ok("skill_model2"))
  dict.get(methods, "/catalog") |> should.equal(Ok("catalog_"))
  dict.get(methods, "/__init__") |> should.equal(Ok("__init___"))
}

pub fn valid_names_accept_slash_tokens_only_test() {
  command.valid_name("/model") |> should.be_true
  command.valid_name("/skill:model") |> should.be_true
  command.valid_name("/snake_case") |> should.be_true
  command.valid_name("/") |> should.be_false
  command.valid_name("/bad command") |> should.be_false
  command.valid_name("model") |> should.be_false
}

pub fn call_rejects_both_argument_spellings_test() {
  let commands = [demo()]
  command.call(
    commands,
    stub_context(),
    ModelCall,
    "kernel",
    "/demo",
    dict.from_list([#("arguments", "x")]),
    "raw",
  )
  |> should.equal(Error("pass either arguments or args, not both"))
  // Raw text and declared names each resolve on their own.
  let assert Ok(Data(_)) =
    command.call(
      commands,
      stub_context(),
      ModelCall,
      "kernel",
      "/demo",
      dict.new(),
      "raw text",
    )
}

pub fn run_requests_decode_strictly_test() {
  let assert Ok(#("/demo", supplied, raw, client)) =
    command.decode_run(
      ["name", "args", "arguments", "clientId"],
      dynamic_json(
        "{\"name\":\"/demo\",\"args\":{\"arguments\":\"one  two\"},\"clientId\":\"c\"}",
      ),
    )
  supplied |> should.equal(dict.from_list([#("arguments", "one  two")]))
  raw |> should.equal("")
  client |> should.equal("c")
  // Unknown fields and non-string values fail with a precise reason.
  let assert Error(message) =
    command.decode_run(
      ["name", "args", "arguments", "clientId"],
      dynamic_json("{\"name\":\"/demo\",\"nmae\":\"typo\"}"),
    )
  message |> should.equal("unknown fields: nmae")
  let assert Error(page_message) =
    command.decode_run(
      ["name", "args", "arguments", "clientId"],
      dynamic_json("{\"name\":\"/context\",\"args\":{\"page\":3}}"),
    )
  page_message |> should.equal("String")
}

@external(erlang, "albedo_command_test_support_json", "parse")
fn dynamic_json(text: String) -> decode.Dynamic

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

pub fn user_turn_is_enforced_in_both_directions_test() {
  // A user-turn command that returns data violates its declaration.
  let confused =
    Command("/confused", "", [], True, True, fn(_, _, _) {
      Ok(Data(json.string("data")))
    })
  command.dispatch(
    [confused],
    stub_context(),
    UserCall,
    "client",
    "/confused",
    dict.new(),
  )
  |> should.equal(Error("/confused is a user-turn command but returned data"))
  // A plain command that returns a turn violates its declaration.
  let sneaky =
    Command("/sneaky", "", [], True, False, fn(_, _, _) {
      Ok(Turn("display", "text"))
    })
  command.dispatch(
    [sneaky],
    stub_context(),
    UserCall,
    "client",
    "/sneaky",
    dict.new(),
  )
  |> should.equal(Error(
    "/sneaky returned a turn but is not a user-turn command",
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

pub fn reload_declares_models_as_its_first_required_target_test() {
  let values = extension.commands([commands.extension()])
  let assert Ok(reload) = command.find(values, "/reload")
  command.usage(reload) |> should.equal("/reload <target>")
  let assert [Argument(_, _, _, choices)] = reload.arguments
  choices |> should.equal(["models"])
  reload.model_callable |> should.be_false
  command.dispatch(
    values,
    stub_context(),
    UserCall,
    "c",
    "/reload",
    dict.from_list([#("target", "plugins")]),
  )
  |> should.equal(Error("unknown reload target plugins; available: models"))
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
  // A provider without a model is rejected, not silently ignored.
  command.dispatch(
    values,
    stub_context(),
    UserCall,
    "c",
    "/model",
    dict.from_list([#("provider", "acme")]),
  )
  |> should.equal(Error("provider requires model"))
}

pub fn catalog_carries_usage_and_mintable_methods_test() {
  let catalog =
    command.catalog_json([
      demo(),
      Command(
        "/skill-model",
        "",
        [Argument("x", "", True, [])],
        True,
        False,
        fn(_, _, _) { Ok(Data(json.string(""))) },
      ),
    ])
    |> json.to_string
  catalog
  |> should.equal(
    "[{\"name\":\"/demo\",\"description\":\"Demo\",\"method\":\"demo\","
    <> "\"usage\":\"/demo [arguments]\",\"arguments\":[{\"name\":\"arguments\","
    <> "\"description\":\"freeform\",\"required\":false}],\"modelCallable\":true,"
    <> "\"userTurn\":true},{\"name\":\"/skill-model\",\"description\":\"\","
    <> "\"method\":\"skill_model\",\"usage\":\"/skill-model <x>\","
    <> "\"arguments\":[{\"name\":\"x\",\"description\":\"\",\"required\":true}],"
    <> "\"modelCallable\":true,\"userTurn\":false}]",
  )
}
