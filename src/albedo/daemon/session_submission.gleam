//// One submission's model input and its durable user-visible event.

import albedo/daemon/events as view
import albedo/daemon/note
import albedo/daemon/session_state
import albedo/daemon/turn.{type Submission}
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

fn event(submission: Submission, timestamp: Int) -> String {
  let source = turn.source_name(submission.source)
  let client = Some(submission.client_id)
  case submission.image {
    Some(image) ->
      view.user_image(
        submission.display,
        source,
        client,
        Some(timestamp),
        image,
      )
    None -> view.user(submission.display, source, client, Some(timestamp))
  }
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
