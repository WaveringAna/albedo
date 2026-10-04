//// Finite monitored calls shared by actors and their clients.

import gleam/erlang/process.{type Subject}

/// Why a call came back without a reply. The two cases need different
/// treatment: a timeout leaves the callee alive and the request possibly
/// already processed, while a dead callee means nothing will ever answer.
pub type CallError {
  TimedOut
  CalleeDown
}

/// Call an actor without panicking on a timeout or callee exit. The timeout
/// bounds the wait; it does not cancel work already accepted by the callee.
/// The caller chooses how to handle each failure.
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
