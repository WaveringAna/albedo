//// Session commands: one catalog drives the CLI menu, user invocation, and the
//// Python kernel's typed `commands` bindings.
////
//// A command runs outside the session actor — on the kernel's host-call process
//// or an HTTP request process — and reaches session state only through
//// `Context.state`, which serializes on the session actor. A handler running
//// inside that actor must never run a command itself: its state calls would
//// deadlock against the actor it is running in.

import albedo/daemon/store
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string

/// One command argument, in invocation order.
pub type Argument {
  Argument(name: String, description: String, required: Bool)
}

/// Who invoked the command. Runs branch only where the two faces genuinely
/// differ: a user invocation may submit a turn, a model invocation returns data.
pub type Caller {
  UserCall
  ModelCall
}

pub type Outcome {
  /// A JSON value for the invoking caller.
  Data(json.Json)
  /// One user turn: the label shown in the transcript and the model-visible text.
  Turn(display: String, text: String)
}

/// Capabilities handed to a running command.
///
/// `state` addresses session state by operation name with string arguments:
/// "model.get" (no arguments), "model.select" (model, provider?), "context.summary"
/// (no arguments), "context.page" (section, page), and "submit" (display, text,
/// client). Unknown operations answer an error. This is the seam between
/// harness commands and daemon state; both sides live behind it.
pub type Context {
  Context(
    session: String,
    store: store.Store,
    state: fn(String, Dict(String, String)) -> Result(json.Json, String),
  )
}

pub type Command {
  Command(
    /// The slash spelling, e.g. "/model".
    name: String,
    description: String,
    /// Declared in invocation order. The last argument takes the rest of the raw
    /// invocation: outer whitespace trims, inner spacing stays exact.
    arguments: List(Argument),
    /// False for commands only a user may invoke.
    model_callable: Bool,
    /// User invocations submit the outcome as a user turn instead of returning it.
    user_turn: Bool,
    run: fn(Context, Caller, Dict(String, String)) -> Result(Outcome, String),
  )
}

/// The context every dispatch path builds: state serializes through the
/// session's registered command bridge.
pub fn context(store: store.Store, session: String) -> Context {
  Context(session, store, fn(op, args) { state_call(session, op, args) })
}

@external(erlang, "albedo_commands", "call")
fn state_call(
  session: String,
  op: String,
  args: Dict(String, String),
) -> Result(json.Json, String)

const identifier_characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"

const digits = "0123456789"

/// The Python binding name minted for one command: `/model` -> "model",
/// `/fix-lint` -> "fix_lint". Carried in the catalog so both sides agree.
pub fn method_name(name: String) -> String {
  let mangled =
    string.replace(name, "/", "")
    |> string.to_graphemes
    |> list.map(fn(char) {
      case string.contains(identifier_characters, char) {
        True -> char
        False -> "_"
      }
    })
    |> string.join("")
  case string.first(mangled) {
    Error(_) -> "command"
    Ok(char) ->
      case string.contains(digits, char) {
        True -> "_" <> mangled
        False -> mangled
      }
  }
}

/// Split one raw invocation into declared arguments. Leading arguments take one
/// whitespace token each; the last declared argument takes the rest with outer
/// whitespace trimmed and inner spacing exact, so `/fix-lint one  two` reaches
/// the command as "one  two". Missing required arguments answer a usage error.
pub fn parse_arguments(
  command: Command,
  raw: String,
) -> Result(Dict(String, String), String) {
  use values <- result.try(
    take_arguments(command.arguments, string.trim(raw), []),
  )
  Ok(dict.from_list(values))
}

fn take_arguments(
  arguments: List(Argument),
  raw: String,
  taken: List(#(String, String)),
) -> Result(List(#(String, String)), String) {
  case arguments, raw {
    [], "" -> Ok(list.reverse(taken))
    [], _ -> Error("usage: command takes no arguments")
    [argument], _ -> {
      let value = string.trim(raw)
      case value, argument.required {
        "", True -> missing(argument)
        "", False -> Ok(list.reverse(taken))
        _, _ -> Ok(list.reverse([#(argument.name, value), ..taken]))
      }
    }
    [argument, ..rest], _ -> {
      let #(token, remainder) = case string.split_once(raw, " ") {
        Ok(#(token, remainder)) -> #(string.trim(token), string.trim(remainder))
        Error(_) -> #(string.trim(raw), "")
      }
      case token, argument.required {
        "", True -> missing(argument)
        "", False -> take_arguments(rest, remainder, taken)
        _, _ ->
          take_arguments(rest, remainder, [#(argument.name, token), ..taken])
      }
    }
  }
}

fn missing(argument: Argument) -> Result(List(#(String, String)), String) {
  Error("missing argument <" <> argument.name <> ">")
}

fn usage(command: Command) -> String {
  let arguments =
    command.arguments
    |> list.map(fn(argument) {
      case argument.required {
        True -> "<" <> argument.name <> ">"
        False -> "[" <> argument.name <> "]"
      }
    })
  string.join([command.name, ..arguments], " ")
}

/// Validate supplied arguments against the declaration: unknown names fail,
/// and every required argument must be present and nonempty.
pub fn check_arguments(
  command: Command,
  args: Dict(String, String),
) -> Result(Dict(String, String), String) {
  use _ <- result.try(
    dict.to_list(args)
    |> list.try_each(fn(entry) {
      case
        list.any(command.arguments, fn(argument) { argument.name == entry.0 })
      {
        True -> Ok(Nil)
        False -> Error("unknown argument <" <> entry.0 <> ">")
      }
    })
    |> result.map_error(fn(error) { error <> "; usage: " <> usage(command) }),
  )
  use _ <- result.try(
    command.arguments
    |> list.try_each(fn(argument) {
      case argument.required, dict.get(args, argument.name) {
        True, Ok(value) if value != "" -> Ok(Nil)
        True, _ -> Error("missing argument <" <> argument.name <> ">")
        False, _ -> Ok(Nil)
      }
    })
    |> result.map_error(fn(error) { error <> "; usage: " <> usage(command) }),
  )
  Ok(args)
}

pub fn find(commands: List(Command), name: String) -> Result(Command, String) {
  list.find(commands, fn(command) { command.name == name })
  |> result.replace_error("unknown command " <> name)
}

/// Run one command and apply the caller policy. A user invocation of a
/// `user_turn` command submits its turn through state; every other outcome is
/// returned to the caller. A model invocation may never submit a turn.
pub fn dispatch(
  commands: List(Command),
  context: Context,
  caller: Caller,
  client: String,
  name: String,
  args: Dict(String, String),
) -> Result(Outcome, String) {
  use command <- result.try(find(commands, name))
  use args <- result.try(check_arguments(command, args))
  use _ <- result.try(case caller, command.model_callable {
    ModelCall, False -> Error(command.name <> " is not callable from the model")
    _, _ -> Ok(Nil)
  })
  use outcome <- result.try(command.run(context, caller, args))
  case caller, outcome {
    ModelCall, Turn(_, _) ->
      Error(
        command.name
        <> " submits a user turn and cannot run from the model; ask the user to run it",
      )
    UserCall, Turn(display, text) -> {
      use _ <- result.try(
        context.state(
          "submit",
          dict.from_list([
            #("display", display),
            #("text", text),
            #("client", client),
          ]),
        )
        |> result.replace(Nil),
      )
      Ok(Turn(display, text))
    }
    _, data -> Ok(data)
  }
}

/// Parse a raw user invocation and dispatch it.
pub fn invoke(
  commands: List(Command),
  context: Context,
  caller: Caller,
  client: String,
  name: String,
  raw: String,
) -> Result(Outcome, String) {
  use command <- result.try(find(commands, name))
  use args <- result.try(parse_arguments(command, raw))
  dispatch(commands, context, caller, client, name, args)
}

pub fn command_json(command: Command) -> json.Json {
  json.object([
    #("name", json.string(command.name)),
    #("description", json.string(command.description)),
    #("method", json.string(method_name(command.name))),
    #(
      "arguments",
      json.array(command.arguments, fn(argument) {
        json.object([
          #("name", json.string(argument.name)),
          #("description", json.string(argument.description)),
          #("required", json.bool(argument.required)),
        ])
      }),
    ),
    #("modelCallable", json.bool(command.model_callable)),
    #("userTurn", json.bool(command.user_turn)),
  ])
}

pub fn catalog_json(commands: List(Command)) -> json.Json {
  json.array(commands, command_json)
}

/// Metadata-only startup context, so the model knows the catalog before it can
/// call it. The typed bindings are minted from this same list at kernel boot.
/// An empty catalog adds nothing to the request.
pub fn context_block(commands: List(Command)) -> String {
  case commands {
    [] -> ""
    _ -> {
      let rows =
        commands
        |> list.map(fn(command) {
          let arguments =
            command.arguments
            |> list.map(fn(argument) {
              case argument.required {
                True -> "<" <> argument.name <> ">"
                False -> "[" <> argument.name <> "]"
              }
            })
          "  "
          <> command.name
          <> {
            case arguments {
              [] -> ""
              values -> " " <> string.join(values, " ")
            }
          }
          <> {
            case command.model_callable {
              True -> " (method: " <> method_name(command.name) <> ")"
              False -> " (user only)"
            }
          }
          <> ": "
          <> command.description
        })
        |> string.join("\n")
      "Session commands are exposed through the async `commands` object. Every"
      <> " model-callable command is a typed method (commands.<method>(...));"
      <> " commands.catalog() lists the immutable catalog with argument details, and"
      <> " help(commands.<method>) shows one command's help. commands.invoke(name, arguments)"
      <> " runs any model-callable command by its slash name. Invoking a command returns data"
      <> " and never submits a turn.\n<session_commands>\n"
      <> rows
      <> "\n</session_commands>"
    }
  }
}

/// Aggregate `commands.*` kernel routes over one materialized command list.
/// `commands.list` answers from the captured list alone, so it can serve kernel
/// boot; `commands.run` executes outside any session actor.
pub fn routes(
  commands: List(Command),
) -> List(#(String, fn(store.Store, String, String) -> String)) {
  [
    #("commands", fn(store, session, request) {
      respond(commands, store, session, request)
    }),
  ]
}

fn respond(
  commands: List(Command),
  store: store.Store,
  session: String,
  request: String,
) -> String {
  let decoder = {
    use method <- decode.field("method", decode.string)
    use args <- decode.field("args", decode.dynamic)
    decode.success(#(method, args))
  }
  case json.parse(request, decoder) {
    Error(_) -> failed("invalid", "invalid commands host request")
    Ok(#(method, args)) ->
      case method {
        "commands.list" -> answered(catalog_json(commands))
        "commands.run" -> run_request(commands, context(store, session), args)
        _ -> failed("commands", "unknown commands operation")
      }
  }
}

fn run_request(
  commands: List(Command),
  context: Context,
  args: decode.Dynamic,
) -> String {
  let named = {
    use name <- decode.field("name", decode.string)
    use supplied <- decode.optional_field(
      "args",
      dict.new(),
      decode.dict(decode.string, decode.string),
    )
    use raw <- decode.optional_field("arguments", "", decode.string)
    decode.success(#(name, supplied, raw))
  }
  case decode.run(args, named) {
    Error(_) -> failed("commands", "invalid commands run request")
    Ok(#(name, supplied, raw)) -> {
      let prepared = case raw {
        "" -> Ok(supplied)
        text ->
          find(commands, name)
          |> result.try(fn(command) { parse_arguments(command, text) })
      }
      case
        prepared
        |> result.try(fn(args) {
          dispatch(commands, context, ModelCall, "kernel", name, args)
        })
      {
        Ok(Data(value)) -> answered(value)
        Ok(Turn(_, _)) ->
          failed("commands", "command submitted a turn from the model")
        Error(message) -> failed("commands", message)
      }
    }
  }
}

fn answered(value: json.Json) -> String {
  json.object([#("ok", json.bool(True)), #("value", value)]) |> json.to_string
}

fn failed(code: String, message: String) -> String {
  json.object([
    #("ok", json.bool(False)),
    #("code", json.string(code)),
    #("message", json.string(message)),
  ])
  |> json.to_string
}
