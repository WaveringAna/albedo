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
import gleam/string

type Start =
  fn() -> Result(actor.Started(Supervisor), actor.StartError)

/// How many starts in a row may fail after the listener first came up.
pub type Restarts {
  /// The daemon's own port: it comes back however long that takes.
  Always
  /// Stop after `attempts` failed starts in a row and run `stopped`.
  Bounded(attempts: Int, stopped: fn() -> Nil)
}

pub type Failure {
  /// The first start did not finish within the wait. Its keeper is gone, so
  /// nothing it was starting comes up later.
  TimedOut
  Failed(reason: String)
}

pub fn describe(failure: Failure) -> String {
  case failure {
    TimedOut -> "did not start in time"
    Failed(reason) -> reason
  }
}

const first_pause = 250

const longest_pause = 10_000

/// A listener up for this long has settled: the next pause starts over.
const settled_after = 30_000

/// Start the listener under a keeper and report that first attempt within
/// `wait_ms`; later exits restart it as `restarts` allows. The keeper is
/// linked to the caller, so the listener ends with the daemon.
pub fn keep(
  port: Int,
  start: Start,
  wait_ms: Int,
  restarts: Restarts,
) -> Result(Nil, Failure) {
  let outcome = process.new_subject()
  let keeper =
    process.spawn(fn() {
      process.trap_exits(True)
      label("albedo_listener", int.to_string(port))
      case start() {
        Ok(started) -> {
          process.send(outcome, Ok(Nil))
          watch(start, started.pid, first_pause, restarts)
        }
        Error(error) ->
          process.send(outcome, Error(Failed(string.inspect(error))))
      }
    })
  case process.receive(outcome, wait_ms) {
    Ok(reported) -> reported
    Error(Nil) -> {
      // Killed, the keeper takes a half-started tree down with its link
      // instead of bringing the port up after the caller moved on.
      process.unlink(keeper)
      let monitor = process.monitor(keeper)
      process.kill(keeper)
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(_) { Nil })
      |> process.selector_receive_forever
      Error(TimedOut)
    }
  }
}

/// Wait for the listener to exit, then bring it back.
fn watch(start: Start, listener: Pid, pause: Int, restarts: Restarts) -> Nil {
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
  restart(start, "listener " <> how, pause, restarts, 0)
}

/// Pause, then start the listener again; a start that fails pauses longer.
fn restart(
  start: Start,
  why: String,
  pause: Int,
  restarts: Restarts,
  failed: Int,
) -> Nil {
  case restarts {
    Bounded(attempts, stopped) if failed >= attempts -> {
      io.println_error(why <> "; giving the listener up")
      stopped()
    }
    _ -> {
      io.println_error(
        why
        <> "; starting the listener again in "
        <> int.to_string(pause)
        <> " ms",
      )
      process.sleep(pause)
      let next = int.min(pause * 2, longest_pause)
      let again = restart(start, _, next, restarts, failed + 1)
      case start() {
        Ok(started) -> watch(start, started.pid, next, restarts)
        Error(actor.InitTimeout) -> again("listener timed out starting")
        Error(actor.InitFailed(message)) ->
          again("listener did not start: " <> message)
        Error(actor.InitExited(_)) -> again("listener exited while starting")
      }
    }
  }
}

@external(erlang, "albedo_inspect", "label")
fn label(kind: String, id: String) -> Nil
