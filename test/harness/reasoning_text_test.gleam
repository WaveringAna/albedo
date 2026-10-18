//// A reasoning item is never the assistant's answer. A server that streams
//// raw reasoning (`reasoning_text`, as DeepSeek and llama.cpp do) keeps it in
//// the item's `content`, where an answer's text lives too, so the history
//// read it as thinking and then again as a reply.

import albedo/daemon/message_content
import albedo/openai_api/types
import gleam/json
import gleam/option
import gleeunit/should

fn responses(body: String) -> types.ReplayItem {
  let assert Ok(item) = json.parse(body, types.replay_decoder(types.Responses))
  item
}

const raw_reasoning =
  "{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[],\"content\":[{\"type\":\"reasoning_text\",\"text\":\"weighing the two routes\"}]}"

pub fn raw_reasoning_is_thinking_and_not_an_answer_test() -> Nil {
  let item = responses(raw_reasoning)
  message_content.thinking_text(item) |> should.equal("weighing the two routes")
  message_content.output_text(item) |> should.equal("")
  message_content.visible_assistant_text(types.Replay(item))
  |> should.equal(option.None)
}

pub fn a_message_item_is_still_an_answer_test() -> Nil {
  let item =
    responses(
      "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"use the first\"},{\"type\":\"output_text\",\"text\":\" route\"}]}",
    )
  message_content.output_text(item) |> should.equal("use the first route")
  message_content.thinking_text(item) |> should.equal("")
}
