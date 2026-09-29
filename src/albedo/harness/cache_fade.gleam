//// How a call's cached prefix fades once the session goes quiet: the steps
//// the cached count takes as the provider lets its cache go. The count stays
//// a read count throughout, what the next request would find cached, so a
//// step never raises it above what the call itself read.

import albedo/harness/cache_ttl
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}

/// From `after_ms` past the anchor on, a request would read `cached` tokens
/// from cache, or an unknown number when `None`.
pub type Step {
  Step(after_ms: Int, cached: Option(Int))
}

/// One call's fading, anchored at its send's start or finish as the cache
/// table's clock says.
pub type Fade {
  Fade(anchor_ms: Int, from_start: Bool, steps: List(Step))
}

/// The fading of one successful call, or `None` when nothing says when its
/// cache goes. `measured` looks up what the head under the longest-lived
/// marks takes up, as the latest call that wrote it measured.
pub fn fade(
  entry: Option(cache_ttl.Entry),
  marks: List(types.CacheMark),
  usage: Option(types.Usage),
  measured: fn() -> Option(Int),
  started_ms: Int,
  finished_ms: Int,
) -> Option(Fade) {
  let from_start = cache_ttl.from_start(entry)
  let steps = case marks {
    [] -> unmarked(entry)
    marks -> marked(marks, usage, measured)
  }
  case steps {
    [] -> None
    steps ->
      Some(Fade(anchor(from_start, started_ms, finished_ms), from_start, steps))
  }
}

/// The same fading from a later send that repeated the call, such as a
/// warming ping: the provider's clock starts over from it.
pub fn reanchor(fade: Fade, started_ms: Int, finished_ms: Int) -> Fade {
  Fade(..fade, anchor_ms: anchor(fade.from_start, started_ms, finished_ms))
}

fn anchor(from_start: Bool, started_ms: Int, finished_ms: Int) -> Int {
  case from_start {
    True -> started_ms
    False -> finished_ms
  }
}

/// A provider that caches on its own: nothing is left once its clock runs
/// out, or, when it only evicts, the count is unknown past typical survival
/// and nothing is left past the bound.
fn unmarked(entry: Option(cache_ttl.Entry)) -> List(Step) {
  case entry {
    None -> []
    Some(entry) ->
      case cache_ttl.clock_tier(entry), entry.survival {
        Some(tier), _ -> [Step(tier.seconds * 1000, Some(0))]
        None, Some(cache_ttl.Survival(typical, Some(max))) -> [
          Step(typical * 1000, None),
          Step(max * 1000, Some(0)),
        ]
        None, Some(cache_ttl.Survival(typical, None)) -> [
          Step(typical * 1000, None),
        ]
        None, None -> []
      }
  }
}

/// A request that asked for its own cache entries: each shorter-lived one
/// expires into the head, which the longest-lived ones keep until they go
/// too; an unmeasured head leaves the count unknown. Marks of a single
/// lifetime go all at once.
fn marked(
  marks: List(types.CacheMark),
  usage: Option(types.Usage),
  measured: fn() -> Option(Int),
) -> List(Step) {
  let lifetimes =
    marks
    |> list.map(fn(mark) { mark.ttl_seconds })
    |> list.unique
    |> list.sort(int.compare)
    |> list.reverse
  case lifetimes {
    [] -> []
    [longest] -> [Step(longest * 1000, Some(0))]
    [longest, ..shorter] -> {
      let kept = kept(usage, longest, measured)
      let steps =
        shorter
        |> list.reverse
        |> list.map(fn(seconds) { Step(seconds * 1000, kept) })
      list.append(steps, [Step(longest * 1000, Some(0))])
    }
  }
}

/// What of the call's read the longest-lived marks keep once the shorter
/// ones expire. A read covers a prefix and those entries come before the
/// shorter-lived ones, so a call that wrote any read only inside the head and
/// keeps all of it. One that wrote none read the head whole and cannot tell
/// where it ends, so the call that last wrote it has to say.
fn kept(
  usage: Option(types.Usage),
  longest: Int,
  measured: fn() -> Option(Int),
) -> Option(Int) {
  // Only Anthropic splits its writes by lifetime, into 5m and 1h.
  case usage, longest {
    Some(types.Usage(
      cached_input_tokens: Some(read),
      cache_write_1h_tokens: Some(written),
      ..,
    )),
      3600
      if written > 0
    -> Some(read)
    Some(types.Usage(cached_input_tokens: Some(read), ..)), _ ->
      measured() |> option.map(int.min(_, read))
    _, _ -> None
  }
}

/// The steps as clients read them: from `at` on, `cached` tokens, absent
/// when unknown.
pub fn steps_json(fade: Fade) -> Json {
  json.array(fade.steps, fn(step) {
    json.object([
      #("at", json.int(fade.anchor_ms + step.after_ms)),
      ..case step.cached {
        Some(cached) -> [#("cached", json.int(cached))]
        None -> []
      }
    ])
  })
}

/// The stored form, which keeps the anchor apart so a ping can move it.
pub fn to_json(fade: Fade) -> Json {
  json.object([
    #("anchorMs", json.int(fade.anchor_ms)),
    #("fromStart", json.bool(fade.from_start)),
    #(
      "steps",
      json.array(fade.steps, fn(step) {
        json.object([
          #("afterMs", json.int(step.after_ms)),
          #("cached", json.nullable(step.cached, json.int)),
        ])
      }),
    ),
  ])
}

pub fn decoder() -> decode.Decoder(Fade) {
  let step = {
    use after_ms <- decode.field("afterMs", decode.int)
    use cached <- decode.field("cached", decode.optional(decode.int))
    decode.success(Step(after_ms, cached))
  }
  use anchor_ms <- decode.field("anchorMs", decode.int)
  use from_start <- decode.field("fromStart", decode.bool)
  use steps <- decode.field("steps", decode.list(step))
  decode.success(Fade(anchor_ms, from_start, steps))
}
