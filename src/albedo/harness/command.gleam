//// Session commands: one catalog drives the CLI menu, user invocation, and the
//// Python kernel's typed `commands` bindings.
////
//// A command runs outside the session actor — on the kernel's host-call process
//// or an HTTP request process — and reaches session state only through
//// `Context.state`, which serializes on the session actor. A handler running
//// inside that actor must never run a command: its state calls would deadlock
//// against the actor it is running in.

import albedo/daemon/store
import albedo/harness/protect
import albedo/harness/rpc
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

/// One command argument, in invocation order.
pub type Argument {
  Argument(
    name: String,
    description: String,
    required: Bool,
    choices: List(String),
  )
}

/// Who invoked the command. Only a user invocation may submit a turn.
pub type Caller {
  UserCall
  ModelCall
}

pub type Outcome {
  Data(json.Json)
  /// One user turn: the label shown in the transcript and the model-visible text.
  Turn(display: String, text: String)
}

/// Session state a command may reach. The session actor answers these through
/// its registered bridge, reusing its ordinary message handlers; an unknown
/// operation is unrepresentable.
pub type StateOp {
  ModelGet
  ModelSelect(model: String, provider: Option(String), effort: Option(String))
  EffortGet
  EffortSelect(effort: String)
  ContextSummary
  /// Compact now; a named strategy first becomes the session's own.
  Compact(strategy: Option(String))
  ContextPage(section: String, page: Int)
  Submit(display: String, text: String, client: String)
  Refresh
  /// Refetch every enabled model catalog's own list, answering which ones
  /// reloaded and why the rest kept their previous list.
  ReloadCatalogs
  /// Tell the agent something without starting a turn: the note waits in the
  /// session's queue and reaches the model at its next step or next turn.
  /// `origin` labels it in the transcript.
  Note(origin: String, display: String, text: String)
}

/// The dispatch context: `state` is the session's registered command bridge.
pub type Context {
  Context(state: fn(StateOp) -> Result(json.Json, String))
}

pub type Command {
  Command(
    /// The slash spelling, e.g. "/model".
    name: String,
    description: String,
    /// Declared in invocation order; the last argument takes the rest of the raw
    /// invocation with outer whitespace trimmed and inner spacing exact, so
    /// `/fix-lint one  two` reaches the command as "one  two".
    arguments: List(Argument),
    model_callable: Bool,
    /// User invocations submit the outcome as a turn instead of returning it.
    user_turn: Bool,
    /// Run with no arguments, it answers a page document (`page.document`) that
    /// a client renders as the extension's own screen; its actions run this
    /// same command with arguments.
    page: Bool,
    run: fn(Context, Caller, Dict(String, String)) -> Result(Outcome, String),
  )
}

/// The context every dispatch path builds: state serializes through the
/// session's registered command bridge.
pub fn context(session: String) -> Context {
  Context(fn(op) { state_call(session, op) })
}

@external(erlang, "albedo_commands", "call")
fn state_call(session: String, op: StateOp) -> Result(json.Json, String)

const identifier_characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"

const digits = "0123456789"

/// Binding names the Python object reserves for itself.
const reserved_methods = ["catalog", "invoke", "help", "__init__"]

/// The Python binding name of one command: `/model` -> "model",
/// `/fix-lint` -> "fix_lint".
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

/// Every command's minted binding name, computed for the whole catalog:
/// reserved names gain a suffix and collisions gain a numeric suffix, so the
/// name advertised in the catalog and prompt is always the name Python mints.
pub fn method_names(commands: List(Command)) -> Dict(String, String) {
  let #(_taken, pairs) =
    list.fold(commands, #(dict.new(), []), fn(state, command) {
      let #(taken, pairs) = state
      let method = unique_method(method_name(command.name), taken)
      #(dict.insert(taken, method, True), [#(command.name, method), ..pairs])
    })
  dict.from_list(list.reverse(pairs))
}

fn unique_method(base: String, taken: Dict(String, Bool)) -> String {
  let candidate = case list.contains(reserved_methods, base) {
    True -> base <> "_"
    False -> base
  }
  find_free(candidate, taken, 2)
}

fn find_free(candidate: String, taken: Dict(String, Bool), n: Int) -> String {
  case dict.has_key(taken, candidate) {
    False -> candidate
    True -> find_free(candidate <> int.to_string(n), taken, n + 1)
  }
}

/// A slash name is usable in the catalog: one non-space token after the slash.
pub fn valid_name(name: String) -> Bool {
  string.starts_with(name, "/")
  && string.length(string.trim(name)) > 1
  && !string.contains(name, " ")
  && !string.contains(name, "\t")
  && !string.contains(name, "\n")
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
    // The last declared argument takes the rest of the raw text, trimmed at
    // the edges and exact inside.
    [argument], _ ->
      take(argument, string.trim(raw), taken) |> result.map(list.reverse)
    [argument, ..rest], _ -> {
      let #(token, remainder) = case string.split_once(raw, " ") {
        Ok(#(token, remainder)) -> #(string.trim(token), string.trim(remainder))
        Error(_) -> #(string.trim(raw), "")
      }
      use taken <- result.try(take(argument, token, taken))
      take_arguments(rest, remainder, taken)
    }
  }
}

/// One argument's value: the pair onto `taken`, or the usage error an empty
/// required argument answers. `taken` stays newest-first.
fn take(
  argument: Argument,
  value: String,
  taken: List(#(String, String)),
) -> Result(List(#(String, String)), String) {
  case value, argument.required {
    "", True -> Error("missing argument <" <> argument.name <> ">")
    "", False -> Ok(taken)
    _, _ -> Ok([#(argument.name, value), ..taken])
  }
}

/// One command's invocation shape: `/model [model] [provider]`.
pub fn usage(command: Command) -> String {
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

/// Resolve one wire call: declared arguments or raw invocation text, never
/// both. This is the single precedence rule behind both entry paths.
pub fn call(
  commands: List(Command),
  context: Context,
  caller: Caller,
  client: String,
  name: String,
  supplied: Dict(String, String),
  raw: String,
) -> Result(Outcome, String) {
  use command <- result.try(find(commands, name))
  use args <- result.try(case raw, dict.size(supplied) {
    "", _ -> Ok(supplied)
    text, 0 -> parse_arguments(command, text)
    _, _ -> Error("pass either arguments or args, not both")
  })
  run(command, context, caller, client, args)
}

/// Runs one command and applies the caller policy. A user invocation of a
/// `user_turn` command submits its turn through state and otherwise returns
/// data; a model invocation may never submit a turn.
fn run(
  command: Command,
  context: Context,
  caller: Caller,
  client: String,
  args: Dict(String, String),
) -> Result(Outcome, String) {
  use args <- result.try(check_arguments(command, args))
  use _ <- result.try(case caller, command.model_callable {
    ModelCall, False -> Error(command.name <> " is not callable from the model")
    _, _ -> Ok(Nil)
  })
  use outcome <- result.try(
    protect.guarded(fn() { command.run(context, caller, args) }),
  )
  case caller, outcome {
    ModelCall, Turn(_, _) ->
      Error(
        command.name
        <> " submits a user turn and cannot run from the model; ask the user to run it",
      )
    UserCall, Turn(display, text) if command.user_turn -> {
      use _ <- result.try(
        context.state(Submit(display, text, client)) |> result.replace(Nil),
      )
      Ok(Turn(display, text))
    }
    UserCall, Turn(_, _) ->
      Error(command.name <> " returned a turn but is not a user-turn command")
    UserCall, Data(_) if command.user_turn ->
      Error(command.name <> " is a user-turn command but returned data")
    _, data -> Ok(data)
  }
}

pub fn command_json(command: Command, method: String) -> json.Json {
  json.object([
    #("name", json.string(command.name)),
    #("description", json.string(command.description)),
    #("method", json.string(method)),
    #("usage", json.string(usage(command))),
    #(
      "arguments",
      json.array(command.arguments, fn(argument) {
        let fields = [
          #("name", json.string(argument.name)),
          #("description", json.string(argument.description)),
          #("required", json.bool(argument.required)),
        ]
        json.object(case argument.choices {
          [] -> fields
          choices ->
            list.append(fields, [#("choices", json.array(choices, json.string))])
        })
      }),
    ),
    #("modelCallable", json.bool(command.model_callable)),
    #("userTurn", json.bool(command.user_turn)),
    #("page", json.bool(command.page)),
  ])
}

fn method_for(methods: Dict(String, String), command: Command) -> String {
  dict.get(methods, command.name)
  |> result.unwrap(method_name(command.name))
}

pub fn catalog_json(commands: List(Command)) -> json.Json {
  let methods = method_names(commands)
  json.array(commands, fn(command) {
    command_json(command, method_for(methods, command))
  })
}

/// Metadata-only startup context so the model knows the catalog before it can
/// call it, minted from the same list as the typed bindings. An empty catalog
/// adds nothing to the request.
pub fn context_block(commands: List(Command)) -> String {
  case commands {
    [] -> ""
    _ -> {
      let methods = method_names(commands)
      let rows =
        commands
        |> list.map(fn(command) {
          "  "
          <> usage(command)
          <> {
            case command.model_callable {
              True -> " (method: " <> method_for(methods, command) <> ")"
              False -> " (user only)"
            }
          }
          <> ": "
          <> command.description
        })
        |> string.join("\n")
      "Session commands are exposed through the async `commands` object. Every"
      <> " model-callable command is a typed method (commands.<method>(...));"
      <> " commands.catalog() lists the current catalog with argument details, and"
      <> " help(commands.<method>) shows one command's help. commands.invoke(name, arguments)"
      <> " runs any model-callable command by its slash name, including one added by a"
      <> " session reload after the kernel started. Invoking a command returns data and never"
      <> " submits a turn; a refusal raises CommandsError.\n<session_commands>\n"
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
  _store: store.Store,
  session: String,
  request: String,
) -> String {
  case rpc.decode(request) {
    Ok(#("commands.list", _)) -> rpc.reply(Ok(catalog_json(commands)))
    Ok(#("commands.run", args)) -> run_request(commands, session, args)
    Ok(_) -> rpc.refuse("commands", "unknown commands operation")
    Error(_) -> rpc.refuse("invalid", "invalid commands host request")
  }
}

fn run_request(
  commands: List(Command),
  session: String,
  args: decode.Dynamic,
) -> String {
  case decode_run(["name", "args", "arguments"], args) {
    Error(message) -> rpc.refuse("commands", message)
    Ok(#(name, supplied, raw, _)) ->
      case
        call(
          commands,
          context(session),
          ModelCall,
          "kernel",
          name,
          supplied,
          raw,
        )
      {
        Ok(Data(value)) -> rpc.reply(Ok(value))
        Ok(Turn(_, _)) ->
          rpc.refuse("commands", "command submitted a turn from the model")
        Error(message) -> rpc.refuse("commands", message)
      }
  }
}

/// Decode one run request strictly: unknown fields fail, non-string argument
/// values fail, and `arguments` (raw text) and `args` (declared names) are
/// mutually exclusive at `call`.
pub fn decode_run(
  allowed: List(String),
  args: decode.Dynamic,
) -> Result(#(String, Dict(String, String), String, String), String) {
  let decoder = {
    use fields <- decode.then(decode.dict(decode.string, decode.dynamic))
    use name <- decode.field("name", decode.string)
    use supplied <- decode.optional_field(
      "args",
      dict.new(),
      decode.dict(decode.string, decode.string),
    )
    use raw <- decode.optional_field("arguments", "", decode.string)
    use client <- decode.optional_field("clientId", "", decode.string)
    use _ <- decode.then(case unknown_fields(fields, allowed) {
      [] -> decode.success(Nil)
      names ->
        decode.failure(Nil, "unknown fields: " <> string.join(names, ", "))
    })
    decode.success(#(name, supplied, raw, client))
  }
  decode.run(args, decoder)
  |> result.map_error(fn(errors) {
    list.first(errors)
    |> result.map(fn(error) { error.expected })
    |> result.unwrap("invalid commands run request")
  })
}

fn unknown_fields(
  fields: Dict(String, decode.Dynamic),
  allowed: List(String),
) -> List(String) {
  fields
  |> dict.keys
  |> list.filter(fn(key) { !list.contains(allowed, key) })
  |> list.sort(string.compare)
}
