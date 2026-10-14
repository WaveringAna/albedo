/// A slow first start and a bounded restart are timing races E2E cannot
/// set up on demand.
import albedo/daemon/listener
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleeunit/should

pub fn a_start_that_outlives_its_wait_never_comes_up_test() -> Nil {
  let started = process.new_subject()
  listener.keep(
    0,
    fn() {
      process.sleep(200)
      process.send(started, Nil)
      static_supervisor.new(static_supervisor.OneForOne)
      |> static_supervisor.start
    },
    50,
    listener.Always,
  )
  |> should.equal(Error(listener.TimedOut))
  process.receive(started, 400) |> should.equal(Error(Nil))
}

pub fn a_bounded_listener_stops_after_its_failed_restarts_test() -> Nil {
  let trees = process.new_subject()
  let calls = process.new_subject()
  let stopped = process.new_subject()
  let start = fn() {
    // The start runs in the keeper, so its process dictionary counts calls.
    let call = count("listener_test_calls")
    process.send(calls, call)
    case call {
      1 -> {
        let assert Ok(tree) =
          static_supervisor.new(static_supervisor.OneForOne)
          |> static_supervisor.start
        process.send(trees, tree.pid)
        Ok(tree)
      }
      _ -> Error(actor.InitFailed("port taken"))
    }
  }
  listener.keep(
    0,
    start,
    1000,
    listener.Bounded(2, fn() { process.send(stopped, Nil) }),
  )
  |> should.equal(Ok(Nil))
  let assert Ok(tree) = process.receive(trees, 100)
  process.kill(tree)
  process.receive(stopped, 3000) |> should.equal(Ok(Nil))
  [
    process.receive(calls, 0),
    process.receive(calls, 0),
    process.receive(calls, 0),
    process.receive(calls, 0),
  ]
  |> should.equal([Ok(1), Ok(2), Ok(3), Error(Nil)])
}

fn count(key: String) -> Int {
  let call = case decode.run(get(key), decode.int) {
    Ok(previous) -> previous + 1
    Error(_) -> 1
  }
  put(key, call)
  call
}

@external(erlang, "erlang", "get")
fn get(key: String) -> Dynamic

@external(erlang, "erlang", "put")
fn put(key: String, value: Int) -> Dynamic
