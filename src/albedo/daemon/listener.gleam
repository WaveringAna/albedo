//// A listener the daemon outlives.
////
//// The listener's own supervision tree gives up after a burst of failures:
//// when the process runs out of files, every acceptor crashes at once, and
//// the tree exhausts its restart budget in milliseconds. Linked straight to
//// the daemon, that would end the daemon. A keeper starts the tree instead
//// and, each time the tree exits, starts it again after a pause that doubles
//// up to a cap, so the port comes back once the pressure passes.

import albedo/clock
import gleam/bool
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/io
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor}
import gleam/result
import gleam/string

type Start =
  fn() -> Result(actor.Started(Supervisor), actor.StartError)

const first_pause = 250

const longest_pause = 10_000

/// A listener up for this long has settled: the next pause starts over.
const settled_after = 30_000

/// Start the listener under a keeper and report that first attempt; later
/// exits restart it. The keeper is linked to the caller, so the listener ends
/// with the daemon.
pub fn keep(port: Int, start: Start) -> Result(Nil, String) {
  let outcome = process.new_subject()
  process.spawn(fn() {
    process.trap_exits(True)
    label("albedo_listener", int.to_string(port))
    case start() {
      Ok(started) -> {
        process.send(outcome, Ok(Nil))
        watch(start, started.pid, first_pause)
      }
      Error(error) -> process.send(outcome, Error(string.inspect(error)))
    }
  })
  process.receive(outcome, 5000)
  |> result.replace_error("listener did not start")
  |> result.flatten
}

/// Wait for the listener to exit, then bring it back.
fn watch(start: Start, listener: Pid, pause: Int) -> Nil {
  let began = clock.monotonic_ms()
  let exit =
    process.new_selector()
    |> process.select_trapped_exits(fn(exit) { exit })
    |> process.selector_receive_forever
  // Any other exit is the daemon's: the listener follows this process down.
  use <- bool.guard(exit.pid != listener, Nil)
  let pause = case clock.monotonic_ms() - began >= settled_after {
    True -> first_pause
    False -> pause
  }
  // The supervisor's own report carries the reason; this process must not
  // load code to describe it while the daemon may be out of files.
  let how = case exit.reason {
    process.Normal -> "ended"
    process.Killed -> "was killed"
    process.Abnormal(_) -> "failed"
  }
  restart(start, "listener " <> how, pause)
}

/// Pause, then start the listener again; a start that fails pauses longer.
fn restart(start: Start, why: String, pause: Int) -> Nil {
  io.println_error(
    why <> "; starting the listener again in " <> int.to_string(pause) <> " ms",
  )
  process.sleep(pause)
  let next = int.min(pause * 2, longest_pause)
  case start() {
    Ok(started) -> watch(start, started.pid, next)
    Error(actor.InitTimeout) ->
      restart(start, "listener timed out starting", next)
    Error(actor.InitFailed(message)) ->
      restart(start, "listener did not start: " <> message, next)
    Error(actor.InitExited(_)) ->
      restart(start, "listener exited while starting", next)
  }
}

@external(erlang, "albedo_inspect", "label")
fn label(kind: String, id: String) -> Nil
