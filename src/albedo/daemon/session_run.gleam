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
      Option(Int),
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

/// Why a call came back without a reply. The two cases need different
/// treatment: a timeout leaves the callee alive and the request possibly
/// already processed, while a dead callee means nothing will ever answer.
pub type CallError {
  TimedOut
  CalleeDown
}

/// Call an actor and report a missing reply instead of panicking. `actor.call`
/// raises when the callee is slow or exits mid-call, which killed the worker
/// whenever the session actor stalled past the timeout. The timeout here stays
/// a latency bound, not a death sentence: the caller decides what a missing
/// reply means, and it can tell a stall from a corpse.
pub fn try_call(
  subject: Subject(message),
  waiting timeout: Int,
  sending make_request: fn(Subject(reply)) -> message,
) -> Result(reply, CallError) {
  case process.subject_owner(subject) {
    Error(_) -> Error(CalleeDown)
    Ok(callee) -> {
      let reply = process.new_subject()
      let monitor = process.monitor(callee)
      process.send(subject, make_request(reply))
      let answer =
        process.new_selector()
        |> process.select_map(reply, Ok)
        |> process.select_specific_monitor(monitor, fn(_) { Error(CalleeDown) })
        |> process.selector_receive(timeout)
      process.demonitor_process(monitor)
      case answer {
        Ok(outcome) -> outcome
        Error(_) -> Error(TimedOut)
      }
    }
  }
}

/// What a missing publish reply means for the stream. A timeout only says the
/// session actor is busy: keep streaming, the durable commit lands once it
/// catches up, and an interrupt that landed during the stall is still backed
/// by the Abort timer and the kernel interrupt. A dead session actor ends the
/// stream, so no tool starts without an owner to record its result.
pub fn keep_streaming(outcome: Result(Bool, CallError)) -> Bool {
  case outcome {
    Ok(keep_going) -> keep_going
    Error(TimedOut) -> True
    Error(CalleeDown) -> False
  }
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
      fn(event) {
        keep_streaming(
          try_call(owner, 30_000, messages.publish(run_id, event, _)),
        )
      },
      fn(inputs, stage, thought_ms) {
        actor.call(owner, 10_000, messages.commit(
          run_id,
          inputs,
          stage,
          thought_ms,
          _,
        ))
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
        // The snapshot only feeds the live view, so a stalled session actor
        // must not kill the turn over it; fire and forget after the bound.
        let _ = try_call(owner, 5000, messages.context(run_id, snapshot, _))
        Nil
      },
      fn(metadata) {
        actor.call(owner, 10_000, messages.usage(run_id, metadata, _))
      },
      fn() { actor.call(owner, 10_000, messages.drain(run_id, _)) },
      fn(head) {
        // Same as the context snapshot: the pin report is bookkeeping.
        let _ = try_call(owner, 5000, messages.pin(run_id, head, _))
        Nil
      },
    )
  let pid =
    process.spawn_unlinked(fn() {
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
