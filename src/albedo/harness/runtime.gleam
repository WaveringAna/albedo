//// A small embeddable runtime: shared work ledger and session-owned Python kernels.
//// This module does not start a network server or a model loop.

import albedo/daemon/store
import albedo/harness/compaction
import albedo/harness/plugin
import albedo/harness/plugins
import albedo/harness/python/cells as journal
import albedo/harness/python/kernel as python
import albedo/harness/rpc
import albedo/harness/work/ledger as work
import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

pub opaque type Runtime {
  Runtime(
    subject: Subject(Message),
    work: work.Store,
    plugins: List(plugin.Plugin),
    compaction: Option(compaction.Strategy),
  )
}

pub opaque type Session {
  Session(id: String, cwd: String, kernel: python.Kernel, owner: work.Store)
}

type State {
  State(
    work: work.Store,
    sessions: Dict(String, Session),
    plugins: List(plugin.Plugin),
  )
}

type Message {
  Open(String, String, Subject(Result(Session, python.Error)))
  Reset(String, Subject(Nil))
  Stop(Subject(Nil))
}

pub fn start(database: String) -> Result(Runtime, actor.StartError) {
  start_with_config(database, plugins.defaults())
}

pub fn start_with_plugins(
  database: String,
  plugins: List(plugin.Plugin),
) -> Result(Runtime, actor.StartError) {
  start_with_config(database, plugins.Config(plugins, None))
}

pub fn start_with_config(
  database: String,
  config: plugins.Config,
) -> Result(Runtime, actor.StartError) {
  let plugins = config.tools
  actor.new_with_initialiser(10_000, fn(subject) {
    use ledger <- result.try(
      store.start(
        database,
        "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=3000;",
      )
      |> result.replace_error("could not open storage"),
    )
    case plugin.install(plugins, ledger) {
      Error(error) -> {
        work.close(ledger)
        Error(error)
      }
      Ok(_) ->
        Ok(
          actor.initialised(State(ledger, dict.new(), plugins))
          |> actor.returning(Runtime(
            subject,
            ledger,
            plugins,
            config.compaction,
          )),
        )
    }
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

/// A stop that could not end every process is reported, never assumed.
fn supervise_stop(context: String, kernel: python.Kernel) -> Nil {
  case python.stop(kernel) {
    Ok(_) -> Nil
    Error(report) -> io.println_error(context <> ": " <> report)
  }
}

pub fn ledger(runtime: Runtime) -> work.Store {
  runtime.work
}

pub fn open_session(
  runtime: Runtime,
  id: String,
  cwd: String,
) -> Result(Session, python.Error) {
  case string.trim(id) == "" || string.byte_size(id) > 256 {
    True ->
      Error(python.Invalid("session id must be nonempty and <= 256 bytes"))
    False -> actor.call(runtime.subject, 10_000, Open(id, cwd, _))
  }
}

/// Explicitly discard a namespace. The ledger and saved cells are untouched.
pub fn reset_session(runtime: Runtime, id: String) -> Nil {
  actor.call(runtime.subject, 10_000, Reset(id, _))
}

pub fn stop(runtime: Runtime) -> Nil {
  actor.call(runtime.subject, 10_000, Stop)
}

pub fn alive(session: Session) -> Bool {
  python.alive(session.kernel)
}

pub fn interrupt(session: Session) -> Nil {
  python.interrupt(session.kernel)
}

pub fn events(session: Session) -> List(String) {
  python.events(session.kernel)
}

/// The session kernel's process id, for memory accounting by an owner.
pub fn kernel_pid(session: Session) -> Result(Int, Nil) {
  python.os_pid(session.kernel)
}

/// Write the session namespace to path, or revive one written earlier.
pub fn save_state(
  session: Session,
  path: String,
  timeout_ms: Int,
) -> Result(python.Saved, python.Error) {
  python.snapshot(session.kernel, path, timeout_ms)
}

pub fn load_state(
  session: Session,
  path: String,
  timeout_ms: Int,
) -> Result(python.Saved, python.Error) {
  python.restore(session.kernel, path, timeout_ms)
}

pub type Execution {
  Execution(cell_id: String, result: Result(python.Outcome, python.Error))
}

/// Save source before executing and a native ETF result before acknowledging completion.
/// Storage errors are not permission to retry: the cell may have run.
pub fn execute(
  runtime: Runtime,
  session: Session,
  code: String,
  timeout_ms: Int,
) -> Result(Execution, String) {
  use _ <- result.try(case session.owner == runtime.work {
    True -> Ok(Nil)
    False -> Error("session belongs to another runtime")
  })
  use id <- result.try(journal.begin(runtime.work, session.id, code))
  let outcome = python.execute_saved(session.kernel, id, code, timeout_ms)
  use _ <- result.try(journal.finish(runtime.work, id, outcome))
  Ok(Execution(id, outcome))
}

pub fn cell(runtime: Runtime, id: String) -> Result(journal.Cell, String) {
  journal.get(runtime.work, id)
}

fn handle(state: State, message: Message) {
  case message {
    Open(id, cwd, reply) -> {
      case dict.get(state.sessions, id) {
        Ok(session) -> {
          let answer = case session.cwd == cwd, python.alive(session.kernel) {
            False, _ ->
              Error(python.Invalid(
                "session workspace differs; reset explicitly to change it",
              ))
            _, False -> Error(python.Lost)
            True, True -> Ok(session)
          }
          process.send(reply, answer)
          actor.continue(state)
        }
        Error(_) ->
          case
            python.local_with_plugins(
              state.work,
              cwd,
              rpc.handle(state.plugins, state.work, id, _),
              plugin.modules(state.plugins),
            )
          {
            Error(error) -> {
              process.send(reply, Error(error))
              actor.continue(state)
            }
            Ok(kernel) -> {
              let session = Session(id, cwd, kernel, state.work)
              process.send(reply, Ok(session))
              actor.continue(
                State(
                  ..state,
                  sessions: dict.insert(state.sessions, id, session),
                ),
              )
            }
          }
      }
    }
    Reset(id, reply) -> {
      case dict.get(state.sessions, id) {
        Ok(session) -> supervise_stop("session reset", session.kernel)
        Error(_) -> Nil
      }
      process.send(reply, Nil)
      actor.continue(State(..state, sessions: dict.delete(state.sessions, id)))
    }
    Stop(reply) -> {
      dict.each(state.sessions, fn(_, session) {
        supervise_stop("runtime stop", session.kernel)
      })
      work.close(state.work)
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

pub fn tools(runtime: Runtime) -> List(types.Tool) {
  plugin.tools(runtime.plugins) |> list.map(fn(tool) { tool.definition })
}

pub fn invoke(
  runtime: Runtime,
  session: Session,
  call: types.ToolCall,
) -> Result(types.Input, String) {
  use _ <- result.try(case session.owner == runtime.work {
    True -> Ok(Nil)
    False -> Error("session belongs to another runtime")
  })
  case
    list.find(plugin.tools(runtime.plugins), fn(tool) {
      tool.definition.name == call.name
    })
  {
    Error(_) -> Ok(types.ToolOutput(call.id, "tool is not installed"))
    Ok(tool) ->
      tool.invoke(
        plugin.Context(runtime.work, session.id, session.kernel, call.id),
        call.arguments,
      )
      |> result.map(types.ToolOutput(call.id, _))
  }
}

/// Recovery asks the tool for a saved result, never invokes it again.
pub fn recover(
  runtime: Runtime,
  session: Session,
  call: types.ToolCall,
) -> types.Input {
  let saved = case
    list.find(plugin.tools(runtime.plugins), fn(tool) {
      tool.definition.name == call.name
    })
  {
    Ok(tool) ->
      tool.recover(plugin.Context(
        runtime.work,
        session.id,
        session.kernel,
        call.id,
      ))
    Error(_) -> None
  }
  types.ToolOutput(call.id, case saved {
    Some(output) -> output
    None ->
      "execution interrupted; outcome unknown. Inspect effects before any retry."
  })
}

pub fn instructions(runtime: Runtime) -> String {
  runtime.plugins
  |> list.map(fn(plugin) { plugin.instructions })
  |> string.join("\n")
}

/// Prepare a request view without changing saved conversation or Python state.
pub fn prepare_history(
  runtime: Runtime,
  session: Session,
  model: String,
  history: List(types.Input),
) -> Result(List(types.Input), String) {
  case session.owner == runtime.work, runtime.compaction {
    False, _ -> Error("session belongs to another runtime")
    True, None -> Ok(history)
    True, Some(strategy) ->
      strategy.prepare(
        compaction.Context(runtime.work, session.id, session.kernel, model),
        history,
      )
      |> result.map_error(fn(error) {
        "compaction " <> strategy.name <> ": " <> error
      })
  }
}
