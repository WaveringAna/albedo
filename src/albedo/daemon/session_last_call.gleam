//// The session's last turn call, rebuilt after a daemon restart for the
//// extensions that repeat it, such as the cache warmer. The call itself lived
//// in their memory only; its request row keeps the prefix identity, usage,
//// and timing, and the transcript what it carried, so the request is built
//// again the way the turn built it and kept only when its prefix identity is
//// the row's.

import albedo/daemon/requests
import albedo/daemon/session_history
import albedo/daemon/session_provider
import albedo/daemon/session_state
import albedo/daemon/transcript
import albedo/harness/extension
import albedo/harness/loop
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// The last turn call and the background calls that repeated it since, or
/// `None` when there is none to rebuild or the rebuild is not that call: a
/// later compaction, another model or provider, or a transcript that no
/// longer gives the same request.
pub fn restore(
  state: session_state.State(message),
) -> #(session_state.State(message), Option(#(extension.SentCall, Int))) {
  case rebuild(state) {
    Ok(restored) -> restored
    Error(_) -> #(state, None)
  }
}

fn rebuild(
  state: session_state.State(message),
) -> Result(
  #(session_state.State(message), Option(#(extension.SentCall, Int))),
  String,
) {
  use kernel <- result.try(option.to_result(state.kernel, "no kernel"))
  use last <- result.try(requests.last_turn(
    runtime.ledger(state.host),
    state.info.id,
  ))
  case last {
    None -> Ok(#(state, None))
    Some(#(turn, pings)) -> {
      use state <- result.try(session_history.ensure_history(state))
      use #(state, upstream) <- result.try(session_provider.configured_client(
        state,
      ))
      let through =
        types.protocol_name(upstream.protocol) <> ":" <> upstream.endpoint
      case turn.seq {
        Some(seq)
          if turn.model == state.info.model
          && turn.profile == state.info.provider
          && turn.provider == through
        -> {
          use carried <- result.try(before(state.history, seq))
          use inputs <- result.try(session_history.projected_for(
            Some(carried),
            state.info.provider,
            state.info.protocol,
          ))
          use #(request, prefix) <- result.map(loop.rebuild(
            state.host,
            kernel,
            state.info.model,
            state.info.effort,
            state.pin,
            upstream,
            list.reverse(inputs),
          ))
          #(state, matching(turn, pings, upstream, request, prefix))
        }
        _ -> Ok(#(state, None))
      }
    }
  }
}

/// The rebuilt call, when its prefix identity is the turn row's.
fn matching(
  turn: requests.Row,
  pings: List(requests.Row),
  upstream: extension.Upstream,
  request: types.Request,
  prefix: requests.Prefix,
) -> Option(#(extension.SentCall, Int)) {
  use <- bool.guard(prefix != requests.row_prefix(turn), None)
  let latest = list.last(pings) |> result.unwrap(turn)
  Some(#(
    extension.SentCall(
      request,
      prefix,
      requests.row_usage(turn),
      upstream.cache_marks(request),
      turn.profile,
      upstream.endpoint,
      upstream.protocol,
      latest.started_ms,
      latest.finished_ms,
    ),
    list.length(pings),
  ))
}

/// The loaded transcript, newest first, as it stood before row `seq`.
fn before(
  history: Option(List(transcript.Entry)),
  seq: Int,
) -> Result(List(transcript.Entry), String) {
  use history <- result.try(option.to_result(history, "transcript not loaded"))
  list.try_fold(list.reverse(history), [], fn(kept, entry) {
    case entry.source {
      Some(transcript.SourceRef(_, at)) if at < seq -> Ok([entry, ..kept])
      Some(_) -> Ok(kept)
      None -> Error("a transcript entry without its row")
    }
  })
}
