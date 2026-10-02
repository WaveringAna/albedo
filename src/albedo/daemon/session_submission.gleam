//// One submission's model input and its durable user-visible event.

import albedo/daemon/events as view
import albedo/daemon/note
import albedo/daemon/operations
import albedo/daemon/session_state
import albedo/daemon/turn.{type Submission}
import albedo/openai_api/types
import gleam/json
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

pub fn event(submission: Submission, timestamp: Int) -> String {
  view.durable_submission(display(submission), timestamp)
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
  timestamp: Int,
) -> session_state.State(message) {
  list.fold(submissions, state, fn(state, submission) {
    case submission.source {
      turn.Continue -> state
      _ -> session_state.emit(state, event(submission, timestamp))
    }
  })
}

@external(erlang, "erlang", "term_to_binary")
pub fn encode(submission: Submission) -> BitArray

@external(erlang, "albedo_session", "decode_submission")
pub fn decode(payload: BitArray) -> Submission

@external(erlang, "albedo_session", "fingerprint")
pub fn image_fingerprint(image: types.Image) -> String

pub fn commits(
  submissions: List(Submission),
  offset: Int,
) -> List(operations.Commit) {
  let #(_, commits) =
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
        None -> acc.1
        Some(id) ->
          list.append(acc.1, [
            operations.Commit(id, position, display(submission)),
          ])
      })
    })
  commits
}

pub fn inputs(submissions: List(Submission)) -> List(types.Input) {
  list.filter(submissions, fn(submission) { submission.source != turn.Continue })
  |> list.map(input)
}

pub fn membership(
  state: session_state.State(message),
  id: String,
) -> session_state.State(message) {
  session_state.emit(
    state,
    view.event("turn_membership", [
      #("turnId", json.string(id)),
      #(
        "submissionIds",
        json.array(
          list.filter_map(state.active_submissions, fn(submission) {
            case submission.submission_id {
              Some(id) -> Ok(id)
              None -> Error(Nil)
            }
          }),
          json.string,
        ),
      ),
    ]),
  )
}
