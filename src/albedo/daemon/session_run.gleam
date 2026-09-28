//// The worker executes model/tool work; the session actor owns its protocol.

import albedo/daemon/context_snapshot
import albedo/daemon/conversation
import albedo/daemon/session_state
import albedo/daemon/turn
import albedo/daemon/usage
import albedo/daemon/warm
import albedo/harness/extension
import albedo/harness/loop
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}

pub type Messages(message) {
  Messages(
    publish: fn(String, String, Subject(Bool)) -> message,
    commit: fn(
      String,
      List(types.Input),
      conversation.Stage,
      Option(Int),
      Subject(Result(#(Int, Option(Int)), String)),
    ) -> message,
    context: fn(String, context_snapshot.Snapshot, Bool, Subject(Nil)) ->
      message,
    usage: fn(String, usage.Metadata, Subject(Result(Nil, String))) -> message,
    drain: fn(String, Subject(Result(List(types.Input), String))) -> message,
    pin: fn(String, Option(Int), Subject(Nil)) -> message,
    sent: fn(String, warm.Sent, Subject(Nil)) -> message,
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

/// The worker's publish, which also gates every tool call. A timeout only
/// says the session actor is busy: keep streaming, the durable commit lands
/// once it catches up. Once the session has cancelled the run, though, a
/// timeout stops it: the kernel interrupt that backs a late-started tool
/// cannot reach a tool outside the kernel, such as an MCP call. A dead session
/// actor ends the stream, so no tool starts without an owner to record its
/// result.
pub fn publish_fn(
  owner: Subject(message),
  run_id: String,
  messages: Messages(message),
  stop: turn.Latch,
  waiting timeout: Int,
) -> fn(String) -> Bool {
  fn(event) {
    case try_call(owner, timeout, messages.publish(run_id, event, _)) {
      Ok(keep_going) -> keep_going
      Error(TimedOut) -> !turn.raised(stop)
      Error(CalleeDown) -> False
    }
  }
}

/// The calls whose replies the turn cannot go on without. None is retried: a
/// timed-out request may already be applied, and a second commit would write
/// its inputs twice. Either miss ends the turn with an error, as a stopped
/// worker does; after a stall the session still applies the pending request
/// once it catches up, then records the turn as interrupted.
fn confirm(
  owner: Subject(message),
  what: String,
  waiting timeout: Int,
  sending make_request: fn(Subject(Result(reply, String))) -> message,
) -> Result(reply, String) {
  case try_call(owner, timeout, make_request) {
    Ok(reply) -> reply
    Error(TimedOut) ->
      Error(what <> " unconfirmed after a session stall; it may still be saved")
    Error(CalleeDown) -> Error(what <> " unconfirmed: the session stopped")
  }
}

/// The worker's commit answers the daemon time and the seq of the commit's
/// first assistant row, so the loop can link a recorded provider call to the
/// transcript row it produced.
pub fn commit_fn(
  owner: Subject(message),
  run_id: String,
  messages: Messages(message),
  waiting timeout: Int,
) -> fn(List(types.Input), conversation.Stage, Option(Int)) ->
  Result(#(Int, Option(Int)), String) {
  fn(inputs, stage, thought_ms) {
    confirm(owner, "commit", timeout, messages.commit(
      run_id,
      inputs,
      stage,
      thought_ms,
      _,
    ))
  }
}

pub fn usage_fn(
  owner: Subject(message),
  run_id: String,
  messages: Messages(message),
  waiting timeout: Int,
) -> fn(usage.Metadata) -> Result(Nil, String) {
  fn(metadata) {
    confirm(owner, "usage", timeout, messages.usage(run_id, metadata, _))
  }
}

pub fn drain_fn(
  owner: Subject(message),
  run_id: String,
  messages: Messages(message),
  waiting timeout: Int,
) -> fn() -> Result(List(types.Input), String) {
  fn() { confirm(owner, "steering", timeout, messages.drain(run_id, _)) }
}

/// Bookkeeping the turn can go on without: a stalled session actor must not
/// kill the turn over it; fire and forget after the bound.
fn report(owner: Subject(message), make: fn(Subject(Nil)) -> message) -> Nil {
  let _ = try_call(owner, 5000, make)
  Nil
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
  let stop = turn.latch()
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
      publish_fn(owner, run_id, messages, stop, 30_000),
      commit_fn(owner, run_id, messages, 10_000),
      fn(request, observation, compacted) {
        let snapshot =
          context_snapshot.from_request(
            Some(usage.now()),
            provider,
            conversation.protocol(protocol),
            protocol,
            request,
            observation,
          )
        // Inspection and post-compaction cleanup must not kill the turn if
        // the session actor stalls; leave the message queued after the bound.
        report(owner, messages.context(run_id, snapshot, compacted, _))
      },
      usage_fn(owner, run_id, messages, 10_000),
      drain_fn(owner, run_id, messages, 10_000),
      fn(head) { report(owner, messages.pin(run_id, head, _)) },
      fn(request, prefix, marks, usage, started, finished) {
        report(owner, messages.sent(
          run_id,
          warm.Sent(
            request,
            prefix,
            usage,
            marks,
            client.endpoint,
            started,
            finished,
          ),
          _,
        ))
      },
      // The request ledger's identity for this session's provider calls.
      state.info.id,
      state.info.provider,
    )
  let pid =
    process.spawn_unlinked(fn() {
      label("albedo_worker", run_id)
      process.send(
        owner,
        messages.finished(run_id, case work {
          turn.Compaction -> loop.compact(worker, model_history)
          turn.Turn(_) -> loop.run(worker, run_id, model_history, 0)
          // A ping never starts here; start_warm owns its worker.
          turn.Warm -> Error("warm pings run through start_warm")
        }),
      )
    })
  let run = turn.Run(run_id, pid, process.monitor(pid), False, stop, work)
  // The worker holds the projected history it runs on; the session's copy is
  // released until the next load, since every commit is durable first.
  process.send(owner, messages.collect)
  session_state.State(
    ..state,
    history: None,
    activity: turn.Running(run),
    context: case work {
      turn.Compaction | turn.Warm -> state.context
      turn.Turn(_) -> session_state.unprepared()
    },
  )
}

/// One cache-warming ping: `sent`'s request re-sent with a tiny output
/// budget. It commits nothing and publishes nothing, so its worker carries
/// no history and answers only its own outcome and usage; the session queues
/// submissions behind it as it does for a compaction run. The run never
/// announces itself on the agents bus: an idle session stays idle.
pub fn start_warm(
  state: session_state.State(message),
  kernel: runtime.Session,
  client: extension.Upstream,
  sent: warm.Sent,
  finished: fn(String, Result(Option(types.Usage), String)) -> message,
) -> session_state.State(message) {
  let run_id = new_id()
  let owner = state.self
  // The worker's closures must capture these fields, never `state`: the
  // session state carries the loaded transcript.
  let worker =
    loop.Loop(
      state.info.model,
      state.info.effort,
      state.host,
      kernel,
      state.pin,
      client,
      // A ping must never show on the session's stream, and must never
      // block on it either.
      fn(_event) { True },
      fn(_inputs, _stage, _thought) { Error("a warm ping never commits") },
      fn(_request, _observation, _compacted) { Nil },
      fn(_metadata) { Ok(Nil) },
      fn() { Ok([]) },
      fn(_head) { Nil },
      fn(_request, _prefix, _marks, _usage, _started, _finished) { Nil },
      state.info.id,
      state.info.provider,
    )
  let pid =
    process.spawn_unlinked(fn() {
      label("albedo_warm", run_id)
      process.send(
        owner,
        finished(run_id, loop.warm(worker, sent.request, sent.prefix)),
      )
    })
  session_state.State(
    ..state,
    activity: turn.Running(turn.Run(
      run_id,
      pid,
      process.monitor(pid),
      False,
      turn.latch(),
      turn.Warm,
    )),
  )
}
