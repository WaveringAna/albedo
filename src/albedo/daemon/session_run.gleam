//// The worker executes model/tool work; the session actor owns its protocol.

import albedo/daemon/context_snapshot
import albedo/daemon/conversation
import albedo/daemon/events
import albedo/daemon/requests
import albedo/daemon/session_state
import albedo/daemon/session_submission
import albedo/daemon/transcript
import albedo/daemon/turn
import albedo/daemon/usage
import albedo/harness/extension
import albedo/harness/loop
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}

pub type Messages(message) {
  Messages(
    publish: fn(String, events.Event, Subject(Bool)) -> message,
    tool_progress_delta: fn(
      String,
      Int,
      Int,
      Int,
      String,
      String,
      Subject(Bool),
    ) -> message,
    tool_progress_running: fn(
      String,
      Int,
      Int,
      Int,
      String,
      String,
      Subject(Bool),
    ) -> message,
    tool_progress_reset: fn(String, Int, Subject(Nil)) -> message,
    tool_progress_finish: fn(String, String, Subject(Nil)) -> message,
    commit: fn(
      String,
      List(types.Input),
      conversation.Stage,
      Option(Int),
      Subject(Result(#(Int, Option(Int)), String)),
    ) -> message,
    fits: fn(String, List(transcript.ImageFit), Subject(Result(Nil, String))) ->
      message,
    context: fn(String, context_snapshot.Snapshot, Bool, Subject(Nil)) ->
      message,
    usage: fn(String, usage.Metadata, Subject(Result(Nil, String))) -> message,
    drain: fn(String, Subject(Result(List(types.Input), String))) -> message,
    pin: fn(String, Option(Int), Subject(Nil)) -> message,
    sent: fn(String, extension.SentCall, Subject(Nil)) -> message,
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

/// General events tolerate a session stall while the run remains live. A
/// cancellation or dead owner refuses continuation; progress acknowledgments
/// use their stricter policy below.
pub fn publish_fn(
  owner: Subject(message),
  run_id: String,
  messages: Messages(message),
  stop: turn.Latch,
  waiting timeout: Int,
) -> fn(events.Event) -> Bool {
  fn(event) {
    case
      try_call(owner, waiting: timeout, sending: messages.publish(
        run_id,
        event,
        _,
      ))
    {
      Ok(keep_going) -> keep_going
      Error(TimedOut) -> !turn.raised(stop)
      Error(CalleeDown) -> False
    }
  }
}

/// Progress acknowledgments confirm the actor applied the projection. Refuse
/// continuation on a missing acknowledgment so unresolved fragments cannot
/// accumulate and a tool cannot start before its running state is accepted.
pub fn tool_progress_delta_fn(
  owner: Subject(message),
  run_id: String,
  messages: Messages(message),
  stop: turn.Latch,
  waiting timeout: Int,
) -> fn(Int, Int, Int, String, String) -> Bool {
  fn(step, attempt, output_index, name, fragment) {
    case turn.raised(stop) {
      True -> False
      False ->
        case
          try_call(
            owner,
            waiting: timeout,
            sending: messages.tool_progress_delta(
              run_id,
              step,
              attempt,
              output_index,
              name,
              fragment,
              _,
            ),
          )
        {
          Ok(keep_going) -> keep_going && !turn.raised(stop)
          Error(_) -> False
        }
    }
  }
}

pub fn tool_progress_running_fn(
  owner: Subject(message),
  run_id: String,
  messages: Messages(message),
  stop: turn.Latch,
  waiting timeout: Int,
) -> fn(Int, Int, Int, String, String) -> Bool {
  fn(step, attempt, output_index, tool_call_id, name) {
    case turn.raised(stop) {
      True -> False
      False ->
        case
          try_call(
            owner,
            waiting: timeout,
            sending: messages.tool_progress_running(
              run_id,
              step,
              attempt,
              output_index,
              tool_call_id,
              name,
              _,
            ),
          )
        {
          Ok(keep_going) -> keep_going && !turn.raised(stop)
          Error(_) -> False
        }
    }
  }
}

pub fn tool_progress_reset_fn(
  owner: Subject(message),
  run_id: String,
  messages: Messages(message),
) -> fn(Int) -> Nil {
  fn(attempt) {
    report(owner, messages.tool_progress_reset(run_id, attempt, _))
  }
}

pub fn tool_progress_finish_fn(
  owner: Subject(message),
  run_id: String,
  messages: Messages(message),
) -> fn(String) -> Nil {
  fn(progress_id) {
    report(owner, messages.tool_progress_finish(run_id, progress_id, _))
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
  case try_call(owner, waiting: timeout, sending: make_request) {
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
    confirm(owner, "commit", waiting: timeout, sending: messages.commit(
      run_id,
      inputs,
      stage,
      thought_ms,
      _,
    ))
  }
}

fn fits_fn(
  owner: Subject(message),
  run_id: String,
  messages: Messages(message),
  waiting timeout: Int,
) -> fn(List(transcript.ImageFit)) -> Result(Nil, String) {
  fn(fits) {
    confirm(owner, "image fit", waiting: timeout, sending: messages.fits(
      run_id,
      fits,
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
    confirm(owner, "usage", waiting: timeout, sending: messages.usage(
      run_id,
      metadata,
      _,
    ))
  }
}

pub fn drain_fn(
  owner: Subject(message),
  run_id: String,
  messages: Messages(message),
  waiting timeout: Int,
) -> fn() -> Result(List(types.Input), String) {
  fn() {
    confirm(owner, "steering", waiting: timeout, sending: messages.drain(
      run_id,
      _,
    ))
  }
}

/// Bookkeeping the turn can go on without: a stalled session actor must not
/// kill the turn over it; fire and forget after the bound.
fn report(owner: Subject(message), make: fn(Subject(Nil)) -> message) -> Nil {
  let _ = try_call(owner, waiting: 5000, sending: make)
  Nil
}

/// How often a worker waiting on the provider checks its run's stop latch.
/// The check is one atomic read, so the cost is wakeups, and an interrupt
/// settles within one interval of the latch going up.
const stop_poll_ms = 25

/// Run the transport in a linked helper so cancellation and owner death can
/// interrupt even an idle stream. Subjects and monitors are created by the
/// worker that receives them, never by the session actor constructing its loop.
pub fn stoppable(
  upstream: extension.Upstream,
  owner: Subject(message),
  stop: turn.Latch,
) -> extension.Upstream {
  extension.Upstream(..upstream, stream: fn(request, on_event) {
    case process.subject_owner(owner), turn.raised(stop) {
      Error(_), _ | _, True -> Error(types.Cancelled)
      Ok(owner_pid), False -> {
        let monitor = process.monitor(owner_pid)
        let answer = process.new_subject()
        let helper =
          process.spawn(fn() {
            process.send(answer, upstream.stream(request, on_event))
          })
        let selector =
          process.new_selector()
          |> process.select_map(answer, fn(outcome) { outcome })
          |> process.select_specific_monitor(monitor, fn(_) {
            process.unlink(helper)
            process.kill(helper)
            Error(types.Cancelled)
          })
        let outcome = await_stream(helper, selector, stop)
        process.demonitor_process(monitor)
        outcome
      }
    }
  })
}

fn await_stream(
  helper: process.Pid,
  selector: process.Selector(Result(types.Turn, types.Error)),
  stop: turn.Latch,
) -> Result(types.Turn, types.Error) {
  case turn.raised(stop) {
    True -> {
      // Unlink before killing so the helper's forced exit cannot kill its worker.
      process.unlink(helper)
      process.kill(helper)
      Error(types.Cancelled)
    }
    False ->
      case process.selector_receive(selector, stop_poll_ms) {
        Ok(outcome) -> outcome
        Error(Nil) -> await_stream(helper, selector, stop)
      }
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
  run_id: String,
  messages: Messages(message),
) -> session_state.State(message) {
  let state = case work {
    turn.Turn(_) -> session_submission.membership(state, run_id)
    _ -> state
  }
  let owner = state.self
  let stop = turn.latch()
  let client = stoppable(client, owner, stop)
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
      publish_fn(owner, run_id, messages, stop, waiting: 30_000),
      state.generation,
      tool_progress_delta_fn(owner, run_id, messages, stop, waiting: 30_000),
      tool_progress_running_fn(owner, run_id, messages, stop, waiting: 30_000),
      tool_progress_reset_fn(owner, run_id, messages),
      tool_progress_finish_fn(owner, run_id, messages),
      commit_fn(owner, run_id, messages, waiting: 10_000),
      fits_fn(owner, run_id, messages, waiting: 10_000),
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
      usage_fn(owner, run_id, messages, waiting: 10_000),
      drain_fn(owner, run_id, messages, waiting: 10_000),
      fn(head) { report(owner, messages.pin(run_id, head, _)) },
      fn(call) { report(owner, messages.sent(run_id, call, _)) },
      // Who this session's provider requests are recorded under.
      state.info.id,
      state.info.provider,
      run_id,
    )
  let pid =
    process.spawn_unlinked(fn() {
      label("albedo_worker", run_id)
      process.send(
        owner,
        messages.finished(run_id, case work {
          turn.Compaction(..) -> loop.compact(worker, model_history)
          turn.Turn(_) -> loop.run(worker, run_id, model_history, 0)
          // A background call never starts here; start_background owns it.
          turn.Background(_) ->
            Error("background calls run through start_background")
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
      turn.Compaction(..) | turn.Background(_) -> state.context
      turn.Turn(_) -> session_state.unprepared()
    },
  )
}

/// One background call an extension asked for. It commits nothing and
/// publishes nothing, so its worker carries no history and answers only its
/// own outcome and usage, which the session passes on to `reply`, and when
/// it started; the session queues submissions behind it as it does for a
/// compaction run. The run never announces itself on the agents bus: an idle
/// session stays idle.
pub fn start_background(
  state: session_state.State(message),
  client: extension.Upstream,
  request: types.Request,
  prefix: requests.Prefix,
  reply: Subject(Result(Option(types.Usage), String)),
  finished: fn(String, Int, Result(Option(types.Usage), String)) -> message,
) -> session_state.State(message) {
  let run_id = new_id()
  let owner = state.self
  let stop = turn.latch()
  let client = stoppable(client, owner, stop)
  // The worker's closures must capture these fields, never `state`: the
  // session state carries the loaded transcript.
  let worker =
    loop.CallContext(
      runtime.ledger(state.host),
      client,
      state.info.id,
      state.info.provider,
      run_id,
      None,
    )
  let pid =
    process.spawn_unlinked(fn() {
      label("albedo_background", run_id)
      let started = usage.now()
      let outcome = loop.background(worker, request, prefix)
      process.send(owner, finished(run_id, started, outcome))
    })
  session_state.State(
    ..state,
    activity: turn.Running(turn.Run(
      run_id,
      pid,
      process.monitor(pid),
      False,
      stop,
      turn.Background(reply),
    )),
  )
}
