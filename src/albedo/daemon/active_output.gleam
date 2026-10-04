//// Session-owned provisional output, with bounded memory and leased spill files.

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub opaque type Projection {
  Projection(
    home: String,
    session: String,
    generation: String,
    attempt: Int,
    segments: List(Segment),
    raw: Int,
    encoded: Int,
    pending: Int,
    total: Int,
    run_id: Option(String),
    failure: Option(String),
  )
}

type Segment {
  Segment(
    message_id: String,
    run_id: String,
    kind: String,
    bytes: Int,
    elapsed_ms: Option(Int),
    text: String,
    encoded: Int,
    content_id: Option(String),
    pending: String,
  )
}

pub type Snapshot {
  Snapshot(
    message_id: String,
    run_id: String,
    kind: String,
    bytes: Int,
    elapsed_ms: Option(Int),
    text: Option(String),
    content_id: Option(String),
  )
}

pub fn new(home: String, session: String, generation: String) -> Projection {
  Projection(home, session, generation, 1, [], 0, 0, 0, 0, None, None)
}

pub fn namespace(projection: Projection, message_id: String) -> String {
  projection.generation
  <> ":"
  <> int.to_string(projection.attempt)
  <> ":"
  <> message_id
}

pub fn ids(projection: Projection) -> List(String) {
  list.map(projection.segments, fn(segment) { segment.message_id })
}

/// Storage failures make backfill unavailable; provider execution still commits.
pub fn observe(
  projection: Projection,
  run_id: String,
  message_id: String,
  kind: String,
  text: String,
  elapsed_ms: Option(Int),
) -> Projection {
  case projection.failure {
    Some(reason) ->
      failed_segment(projection, run_id, message_id, kind, elapsed_ms, reason)
    None -> {
      let updated = {
        let total = case projection.run_id == Some(run_id) {
          True -> projection.total + string.byte_size(text)
          False -> string.byte_size(text)
        }
        use _ <- result.try(case total <= 67_108_864 {
          True -> Ok(Nil)
          False -> Error("active output exceeds the run size limit")
        })
        let existing =
          list.find(projection.segments, fn(segment) {
            segment.message_id == message_id
          })
        use _ <- result.try(
          case existing, list.length(projection.segments) < 256 {
            Error(_), False -> Error("active output exceeds the segment limit")
            _, _ -> Ok(Nil)
          },
        )
        let segment =
          result.unwrap(
            existing,
            Segment(message_id, run_id, kind, 0, None, "", 2, None, ""),
          )
        let base =
          Projection(
            ..projection,
            total: total,
            run_id: Some(run_id),
            encoded: case existing {
              Error(_) -> projection.encoded + 2
              Ok(_) -> projection.encoded
            },
          )
        use #(base, segment) <- result.try(append_segment(
          base,
          segment,
          text,
          elapsed_ms,
        ))
        let segments = case existing {
          Error(_) -> list.append(base.segments, [segment])
          Ok(_) ->
            list.map(base.segments, fn(previous) {
              case previous.message_id == message_id {
                True -> segment
                False -> previous
              }
            })
        }
        let next = Projection(..base, segments: segments)
        case next.pending >= 16_384 {
          True ->
            case flush(next) {
              Ok(flushed) -> Ok(flushed)
              Error(reason) -> Ok(Projection(..next, failure: Some(reason)))
            }
          False -> Ok(next)
        }
      }
      case updated {
        Ok(updated) -> updated
        Error(reason) ->
          failed_segment(
            projection,
            run_id,
            message_id,
            kind,
            elapsed_ms,
            reason,
          )
      }
    }
  }
}

fn failed_segment(
  projection: Projection,
  run_id: String,
  message_id: String,
  kind: String,
  elapsed_ms: Option(Int),
  reason: String,
) -> Projection {
  let known =
    list.any(projection.segments, fn(segment) {
      segment.message_id == message_id
    })
  let segments = case !known && list.length(projection.segments) < 256 {
    True ->
      list.append(projection.segments, [
        Segment(message_id, run_id, kind, 0, elapsed_ms, "", 0, None, ""),
      ])
    False -> projection.segments
  }
  Projection(..projection, segments: segments, failure: Some(reason))
}

fn append_segment(
  projection: Projection,
  segment: Segment,
  text: String,
  elapsed_ms: Option(Int),
) -> Result(#(Projection, Segment), String) {
  let bytes = string.byte_size(text)
  let next =
    Segment(
      ..segment,
      bytes: segment.bytes + bytes,
      elapsed_ms: case elapsed_ms {
        None -> segment.elapsed_ms
        Some(_) -> elapsed_ms
      },
    )
  case segment.content_id {
    Some(_) ->
      Ok(#(
        Projection(..projection, pending: projection.pending + bytes),
        Segment(..next, pending: segment.pending <> text),
      ))
    None -> {
      let encoded = string.byte_size(json.to_string(json.string(text))) - 2
      let raw = projection.raw + bytes
      let size = projection.encoded + encoded
      case raw <= 65_536 && size <= 65_536 {
        True ->
          Ok(#(
            Projection(..projection, raw: raw, encoded: size),
            Segment(
              ..next,
              text: segment.text <> text,
              encoded: segment.encoded + encoded,
            ),
          ))
        False -> {
          use content_id <- result.try(create(
            projection.home,
            projection.session,
          ))
          case append(projection.home, content_id, 0, segment.text <> text) {
            Error(reason) -> {
              release(projection.home, content_id)
              Error(reason)
            }
            Ok(_) ->
              Ok(#(
                Projection(
                  ..projection,
                  raw: projection.raw - string.byte_size(segment.text),
                  encoded: projection.encoded - segment.encoded,
                ),
                Segment(
                  ..next,
                  text: "",
                  encoded: 0,
                  content_id: Some(content_id),
                ),
              ))
          }
        }
      }
    }
  }
}

fn flush(projection: Projection) -> Result(Projection, String) {
  use segments <- result.try(
    list.try_map(projection.segments, fn(segment) {
      case segment.content_id {
        None -> Ok(segment)
        Some(content_id) -> {
          use _ <- result.try(append(
            projection.home,
            content_id,
            segment.bytes - string.byte_size(segment.pending),
            segment.pending,
          ))
          Ok(Segment(..segment, pending: ""))
        }
      }
    }),
  )
  Ok(Projection(..projection, segments: segments, pending: 0))
}

/// Absolute append offsets make flushing an immutable capture idempotent.
pub fn capture(projection: Projection) -> Result(List(Snapshot), String) {
  capture_segments(projection)
  |> result.replace_error("active_output_unavailable")
}

fn capture_segments(projection: Projection) -> Result(List(Snapshot), String) {
  use _ <- result.try(case projection.failure {
    None -> Ok(Nil)
    Some(reason) -> Error(reason)
  })
  use flushed <- result.try(flush(projection))
  list.try_map(flushed.segments, fn(segment) {
    use _ <- result.try(case segment.content_id {
      None -> Ok(Nil)
      Some(content_id) -> lease(projection.home, projection.session, content_id)
    })
    Ok(Snapshot(
      segment.message_id,
      segment.run_id,
      segment.kind,
      segment.bytes,
      segment.elapsed_ms,
      case segment.content_id {
        None -> Some(segment.text)
        Some(_) -> None
      },
      segment.content_id,
    ))
  })
}

pub fn retire(projection: Projection) -> Projection {
  list.each(projection.segments, fn(segment) {
    case segment.content_id {
      None -> Nil
      Some(content_id) -> release(projection.home, content_id)
    }
  })
  Projection(
    ..projection,
    segments: [],
    raw: 0,
    encoded: 0,
    pending: 0,
    failure: None,
  )
}

pub fn retry(projection: Projection) -> Projection {
  Projection(..retire(projection), attempt: projection.attempt + 1)
}

@external(erlang, "albedo_active_output", "create")
fn create(home: String, session: String) -> Result(String, String)

@external(erlang, "albedo_active_output", "append")
fn append(
  home: String,
  content_id: String,
  offset: Int,
  text: String,
) -> Result(Nil, String)

@external(erlang, "albedo_active_output", "lease")
fn lease(
  home: String,
  session: String,
  content_id: String,
) -> Result(Nil, String)

@external(erlang, "albedo_active_output", "release")
fn release(home: String, content_id: String) -> Nil

@external(erlang, "albedo_active_output", "read")
pub fn read(
  home: String,
  session: String,
  content_id: String,
  offset: Int,
  limit: Int,
  cutoff: Int,
) -> Result(#(String, Int, Bool), String)

@external(erlang, "albedo_active_output", "maintenance")
pub fn maintenance(home: String) -> Nil

@external(erlang, "albedo_active_output", "revoke")
pub fn revoke(home: String, session: String) -> Nil
