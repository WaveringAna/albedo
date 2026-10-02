//// Method-name collisions and reserved Python attributes must map to distinct callable names.

import albedo/harness/command.{
  Argument, Command, Data, ModelCall, Turn, UserCall,
}
import gleam/dict
import gleam/json
import gleam/option.{None}
import gleam/result
import gleeunit/should

fn demo() -> command.Command {
  Command(
    "/demo",
    "Demo",
    [Argument("arguments", "freeform", False, [])],
    True,
    True,
    False,
    None,
    fn(_context, caller, args) {
      let arguments = dict.get(args, "arguments") |> result.unwrap("")
      case caller {
        UserCall -> Ok(Turn("/demo " <> arguments, "turn " <> arguments))
        ModelCall -> Ok(Data(json.string("data " <> arguments)))
      }
    },
  )
}

pub fn method_names_are_mintable_and_collision_free_test() -> Nil {
  command.method_name("/model") |> should.equal("model")
  command.method_name("/fix-lint") |> should.equal("fix_lint")
  command.method_name("/skill:model") |> should.equal("skill_model")
  // A whole catalog disambiguates reserved names and collisions.
  let methods =
    command.method_names([
      demo(),
      Command("/skill:model", "", [], True, False, False, None, fn(_, _, _) {
        Ok(Data(json.string("")))
      }),
      Command("/skill-model", "", [], True, False, False, None, fn(_, _, _) {
        Ok(Data(json.string("")))
      }),
      Command("/catalog", "", [], True, False, False, None, fn(_, _, _) {
        Ok(Data(json.string("")))
      }),
      Command("/__init__", "", [], True, False, False, None, fn(_, _, _) {
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
