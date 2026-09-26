//// The jobs route: a kernel wake notice lands as a submit through the registry.

import albedo/harness/extensions/run/extension as run
import albedo/harness/runtime
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleeunit/should

@external(erlang, "albedo_wakes", "register")
fn register(session: String, submit: fn(String, String) -> run.Wake) -> Nil

@external(erlang, "albedo_wakes", "forget")
fn forget(session: String) -> Nil

type Reply {
  Reply(ok: Bool, code: option.Option(String))
}

fn notice(method: String) -> String {
  json.object([
    #("method", json.string(method)),
    #(
      "args",
      json.object([
        #("display", json.string("job finished (exit_code=0)")),
        #("text", json.string("<system-note>wake</system-note>")),
      ]),
    ),
  ])
  |> json.to_string
}

fn reply_of(answer: String) -> Reply {
  let decoder = {
    use ok <- decode.field("ok", decode.bool)
    use code <- decode.optional_field(
      "code",
      None,
      decode.optional(decode.string),
    )
    decode.success(Reply(ok, code))
  }
  let assert Ok(reply) = json.parse(answer, decoder)
  reply
}

fn store() -> runtime.Runtime {
  let assert Ok(host) = runtime.start(":memory:")
  host
}

pub fn delivered_wake_reaches_the_registered_submit_test() {
  let host = store()
  let seen = process.new_subject()
  register("route-delivered", fn(display, text) {
    process.send(seen, #(display, text))
    run.Delivered
  })
  run.route(runtime.ledger(host), "route-delivered", notice("jobs.completed"))
  |> reply_of
  |> should.equal(Reply(True, None))
  let assert Ok(#("job finished (exit_code=0)", text)) =
    process.receive(seen, 1000)
  text |> should.equal("<system-note>wake</system-note>")
  forget("route-delivered")
}

pub fn busy_wake_answers_with_the_code_the_kernel_retries_test() {
  let host = store()
  register("route-busy", fn(_display, _text) { run.Busy })
  run.route(runtime.ledger(host), "route-busy", notice("jobs.completed"))
  |> reply_of
  |> should.equal(Reply(False, Some("busy")))
  forget("route-busy")
}

pub fn an_unregistered_session_refuses_without_the_retry_code_test() {
  let host = store()
  run.route(runtime.ledger(host), "route-nobody", notice("jobs.completed"))
  |> reply_of
  |> should.equal(Reply(False, Some("unavailable")))
}

pub fn a_crashed_submit_is_unavailable_not_busy_test() {
  let host = store()
  register("route-crash", fn(_display, _text) { panic as "session died" })
  run.route(runtime.ledger(host), "route-crash", notice("jobs.completed"))
  |> reply_of
  |> should.equal(Reply(False, Some("unavailable")))
  forget("route-crash")
}
