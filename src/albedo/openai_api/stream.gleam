import albedo/openai_api/chat
import albedo/openai_api/responses
import albedo/openai_api/sse
import albedo/openai_api/types
import gleam/option.{type Option}
import gleam/result

pub opaque type State {
  Responses(responses.State)
  ChatCompletions(chat.State)
}

/// One stream's reduction. `feed` takes each SSE data payload; `finish`
/// settles the turn when the body ends before a terminal event.
pub type Reducer {
  Reducer(
    feed: fn(String) ->
      Result(#(Reducer, List(types.Event), Option(types.Turn)), types.Error),
    finish: fn() -> Result(types.Turn, types.Error),
  )
}

/// The OpenAI protocols end only on an explicit terminal event.
pub fn reducer(protocol: types.Protocol) -> Reducer {
  wrap(new(protocol))
}

fn wrap(state: State) -> Reducer {
  Reducer(
    feed: fn(data) {
      use #(next, events, turn) <- result.map(feed(state, sse.Event("", data)))
      #(wrap(next), events, turn)
    },
    finish: fn() { Error(types.UnexpectedEnd) },
  )
}

pub fn new(protocol: types.Protocol) -> State {
  case protocol {
    types.Responses -> Responses(responses.new())
    types.ChatCompletions -> ChatCompletions(chat.new())
  }
}

pub fn feed(
  state: State,
  event: sse.Event,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  let sse.Event(_, data) = event
  case state {
    Responses(response_state) -> {
      use #(next, events, turn) <- result.try(responses.feed(
        response_state,
        data,
      ))
      Ok(#(Responses(next), events, turn))
    }
    ChatCompletions(chat_state) -> {
      use #(next, events, turn) <- result.try(chat.feed(chat_state, data))
      Ok(#(ChatCompletions(next), events, turn))
    }
  }
}
