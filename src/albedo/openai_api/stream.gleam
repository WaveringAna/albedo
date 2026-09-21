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
