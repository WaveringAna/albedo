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
  wrap(new(protocol), step, fn(_) { Error(types.UnexpectedEnd) })
}

/// Build a reducer from one state value and its two transitions: `feed`
/// returns the state the next payload reduces, and `finish` settles the turn
/// when the body ends first. A provider with its own wire format starts here.
pub fn wrap(
  state: s,
  feed: fn(s, String) ->
    Result(#(s, List(types.Event), Option(types.Turn)), types.Error),
  finish: fn(s) -> Result(types.Turn, types.Error),
) -> Reducer {
  Reducer(
    feed: fn(data) {
      use #(state, events, turn) <- result.map(feed(state, data))
      #(wrap(state, feed, finish), events, turn)
    },
    finish: fn() { finish(state) },
  )
}

fn step(
  state: State,
  data: String,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  feed(state, sse.Event("", data))
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
  case state {
    Responses(s) -> {
      use #(next, events, turn) <- result.map(responses.feed(s, event.data))
      #(Responses(next), events, turn)
    }
    ChatCompletions(s) -> {
      use #(next, events, turn) <- result.map(chat.feed(s, event.data))
      #(ChatCompletions(next), events, turn)
    }
  }
}
