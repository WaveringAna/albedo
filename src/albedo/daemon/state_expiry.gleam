//// Pure policy for deciding which saved session states are safe to expire.

import gleam/list
import gleam/option.{type Option, Some}

pub type Candidate {
  Candidate(id: String, last_activity: Option(Int), live: Bool, running: Bool)
}

/// Returns idle, non-running sessions past the retention period.
pub fn expired(
  candidates: List(Candidate),
  now: Int,
  retention: Int,
) -> List(String) {
  candidates
  |> list.filter(fn(candidate) {
    case candidate.last_activity, candidate.live, candidate.running {
      Some(last), False, False -> now - last >= retention
      _, _, _ -> False
    }
  })
  |> list.map(fn(candidate) { candidate.id })
}

/// Checks at most daily in production, but follows short test retentions.
pub fn sweep_seconds(retention: Int) -> Int {
  case retention < 86_400 {
    True -> retention
    False -> 86_400
  }
}
