//// One submission's model input and its durable user-visible event.

import albedo/daemon/events as view
import albedo/daemon/note
import albedo/daemon/operations
import albedo/daemon/session_state
import albedo/daemon/turn.{type Submission}
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/list
import gleam/option.{None, Some}

pub fn input(submission: Submission) -> types.Input {
  let text = case submission.source {
    turn.Note(origin) -> note.wrap(origin, submission.text)
    _ -> submission.text
  }
  case submission.image {
    Some(image) -> types.UserImage(text, image)
    None -> types.User(text)
  }
}

/// Read the retained admission after the owner's durable transition.
pub fn observed(
  state: session_state.State(message),
  submission: Submission,
) -> session_state.State(message) {
  case submission.operation_id {
    None -> state
    Some(id) -> observed_id(state, id, Some(display(submission)))
  }
}

fn observed_id(
  state: session_state.State(message),
  id: String,
  display: option.Option(operations.Display),
) -> session_state.State(message) {
  case operations.input_outcome(runtime.ledger(state.host), id) {
    Ok(Some(outcome)) -> session_state.emit(state, view.Input(outcome, display))
    _ -> state
  }
}

pub fn refresh_ids(
  state: session_state.State(message),
  ids: List(String),
) -> session_state.State(message) {
  list.fold(ids, state, fn(state, id) { observed_id(state, id, None) })
}

pub fn display(submission: Submission) -> operations.Display {
  operations.Display(
    submission.display,
    turn.source_name(submission.source),
    submission.client_id,
    submission.operation_id,
    option.map(submission.image, fn(image) {
      let #(mime_type, width, height, bytes) = types.image_meta(image)
      operations.ImageMetadata(mime_type, width, height, bytes)
    }),
  )
}

pub fn emit(
  state: session_state.State(message),
  submissions: List(Submission),
  _timestamp: Int,
) -> session_state.State(message) {
  list.fold(submissions, state, observed)
}

@external(erlang, "erlang", "term_to_binary")
pub fn encode(submission: Submission) -> BitArray

@external(erlang, "albedo_session", "decode_submission")
pub fn decode(payload: BitArray) -> Submission

pub fn commits(
  submissions: List(Submission),
  offset: Int,
) -> List(operations.Commit) {
  let #(_, reversed_commits) =
    list.fold(submissions, #(offset, []), fn(acc, submission) {
      let position = case submission.source {
        turn.Continue -> None
        _ -> Some(acc.0)
      }
      let next = case position {
        None -> acc.0
        Some(_) -> acc.0 + 1
      }
      #(next, case submission.operation_id {
        None ->
          case submission.source, submission.submission_id {
            turn.Mail(id, _), _ | turn.JobWake, Some(id) -> [
              operations.Commit(id, position, display(submission)),
              ..acc.1
            ]
            _, _ -> acc.1
          }
        Some(id) -> [
          operations.Commit(id, position, display(submission)),
          ..acc.1
        ]
      })
    })
  list.reverse(reversed_commits)
}

pub fn inputs(submissions: List(Submission)) -> List(types.Input) {
  list.filter(submissions, fn(submission) { submission.source != turn.Continue })
  |> list.map(input)
}

pub fn membership(
  state: session_state.State(message),
  _id: String,
) -> session_state.State(message) {
  list.fold(state.active_submissions, state, observed)
}
