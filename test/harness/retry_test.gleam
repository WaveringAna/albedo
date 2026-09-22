import albedo/harness/loop
import albedo/openai_api/types
import gleam/option.{None}

@external(erlang, "albedo_retry_test", "reset")
fn reset() -> Nil

@external(erlang, "albedo_retry_test", "next")
fn next() -> Int

pub fn transient_failure_is_retried_up_to_three_attempts_test() {
  reset()
  let turn = types.Turn(None, [], [], None, types.Complete)
  let assert Ok(_) =
    loop.retry_stream(
      fn() {
        case next() {
          1 | 2 -> Error(types.ConnectionError("TLS bad_record_mac"))
          _ -> Ok(turn)
        }
      },
      fn(_) { True },
      1,
    )
  assert next() == 4
  reset()
  assert loop.retry_stream(
      fn() {
        let _ = next()
        Error(types.ConnectionError("broken"))
      },
      fn(_) { True },
      1,
    )
    == Error(types.ConnectionError("broken"))
  assert next() == 4
}

pub fn nontransient_failure_and_cancellation_are_not_retried_test() {
  reset()
  assert loop.retry_stream(
      fn() {
        let _ = next()
        Error(types.ProviderError("invalid"))
      },
      fn(_) { True },
      1,
    )
    == Error(types.ProviderError("invalid"))
  assert next() == 2
  reset()
  assert loop.retry_stream(
      fn() {
        let _ = next()
        Error(types.Timeout)
      },
      fn(_) { False },
      1,
    )
    == Error(types.Cancelled)
  assert next() == 2
}
