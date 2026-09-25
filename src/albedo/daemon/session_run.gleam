//// The worker executes model/tool work; the session actor owns its protocol.

import albedo/daemon/context_snapshot
import albedo/daemon/conversation
import albedo/daemon/session_state
import albedo/daemon/turn
import albedo/daemon/usage
import albedo/harness/extension
import albedo/harness/loop
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor

pub type Messages(message) {
  Messages(
    publish: fn(String, String, Subject(Bool)) -> message,
    commit: fn(
      String,
      List(types.Input),
      conversation.Stage,
      Subject(Result(Int, String)),
    ) -> message,
    context: fn(String, context_snapshot.Snapshot, Subject(Nil)) -> message,
    usage: fn(String, usage.Metadata, Subject(Result(Nil, String))) -> message,
    drain: fn(String, Subject(Result(List(types.Input), String))) -> message,
    pin: fn(String, Option(Int), Subject(Nil)) -> message,
    finished: fn(String, Result(Nil, String)) -> message,
    collect: message,
  )
}

@external(erlang, "albedo_native", "new_id")
fn new_id() -> String

@external(erlang, "albedo_inspect", "label")
fn label(kind: String, id: String) -> Nil

pub fn start(
  state: session_state.State(message),
  kernel: runtime.Session,
  client: extension.Upstream,
  model_history: List(types.Input),
  work: turn.Work,
  messages: Messages(message),
) -> session_state.State(message) {
  let run_id = new_id()
  let owner = state.self
  // The worker's closures must capture these fields, never `state`: a spawn
  // copies everything its closure references, and the session state carries
  // the loaded transcript.
  let provider = state.info.provider
  let protocol = state.info.protocol
  let worker =
    loop.Loop(
      state.info.model,
      state.info.effort,
      state.host,
      kernel,
      state.pin,
      client,
      fn(event) { actor.call(owner, 5000, messages.publish(run_id, event, _)) },
      fn(inputs, stage) {
        actor.call(owner, 10_000, messages.commit(run_id, inputs, stage, _))
      },
      fn(request, observation) {
        let snapshot =
          context_snapshot.from_request(
            Some(usage.now()),
            provider,
            conversation.protocol(protocol),
            protocol,
            request,
            observation,
          )
        actor.call(owner, 5000, messages.context(run_id, snapshot, _))
      },
      fn(metadata) {
        actor.call(owner, 10_000, messages.usage(run_id, metadata, _))
      },
      fn() { actor.call(owner, 10_000, messages.drain(run_id, _)) },
      fn(head) { actor.call(owner, 5000, messages.pin(run_id, head, _)) },
    )
  let pid =
    process.spawn(fn() {
      label("albedo_worker", run_id)
      process.send(
        owner,
        messages.finished(run_id, case work {
          turn.Compaction -> loop.compact(worker, model_history)
          turn.Turn(_) -> loop.run(worker, run_id, model_history, 0)
        }),
      )
    })
  let run = turn.Run(run_id, pid, process.monitor(pid), False, work)
  // The worker holds the projected history it runs on; the session's copy is
  // released until the next load, since every commit is durable first.
  process.send(owner, messages.collect)
  session_state.State(
    ..state,
    history: None,
    activity: turn.Running(run),
    context: case work {
      turn.Compaction -> state.context
      turn.Turn(_) -> session_state.unprepared()
    },
  )
}
