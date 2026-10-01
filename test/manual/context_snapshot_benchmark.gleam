//// Offline inspector retention benchmark; prints one JSON record per run.
//// Run with gleam run -m manual/context_snapshot_benchmark.

import albedo/daemon/context_snapshot
import albedo/openai_api
import albedo/openai_api/types
import gleam/json
import gleam/option.{None, Some}

@external(erlang, "albedo_context_snapshot_probe", "benchmark")
fn benchmark() -> Nil

pub fn main() -> Nil {
  benchmark()
}

pub fn capture(inputs: List(types.Input)) -> context_snapshot.Snapshot {
  context_snapshot.from_request(
    Some(1234),
    "fixture",
    "responses",
    types.Responses,
    openai_api.request("fixture", inputs),
    None,
  )
}

pub fn summary(snapshot: context_snapshot.Snapshot) -> String {
  snapshot |> context_snapshot.summary |> json.to_string
}

pub fn page(snapshot: context_snapshot.Snapshot, index: Int) -> String {
  case context_snapshot.page(snapshot, "history", index) {
    Ok(value) -> json.to_string(value)
    Error(reason) -> reason
  }
}

/// Decode opaque replay through the provider's public decoder.
pub fn replay(payload: String) -> types.Input {
  let encoded =
    json.object([
      #("type", json.string("reasoning")),
      #("opaque", json.string(payload)),
    ])
    |> json.to_string
  let assert Ok(item) =
    json.parse(encoded, types.replay_decoder(types.Responses))
  types.Replay(item)
}
