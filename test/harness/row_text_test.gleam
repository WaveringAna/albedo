//// Provider output reaches the retrieval tools as the text a person reads. The
//// fake provider of the E2E suite never sends the signatures and repeated
//// copies real providers do, so those shapes are rendered here.

import albedo/harness/search
import albedo/harness/tool
import albedo/openai_api/types
import gleam/json
import gleam/string
import gleeunit/should

fn replay(protocol: types.Protocol, raw: String) -> String {
  let assert Ok(item) = json.parse(raw, types.replay_decoder(protocol))
  tool.row_text(types.Replay(item))
}

pub fn a_signed_turn_shows_its_reasoning_and_code_once_test() -> Nil {
  let text =
    replay(
      types.ChatCompletions,
      "{\"role\": \"assistant\", \"content\": \"\", \"reasoning_content\": \"check the flag\", \"reasoning_details\": [{\"blocks\": [{\"signature\": \"CAQSjwoKEAgSGAI4AUIIdGhpbmtpbmcAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\", \"thinking\": \"check the flag\", \"type\": \"thinking\"}, {\"id\": \"t1\", \"input\": {\"code\": \"print(1)\\nprint(2)\"}, \"name\": \"python\", \"type\": \"tool_use\"}], \"type\": \"claude.blocks\"}], \"tool_calls\": [{\"id\": \"t1\", \"type\": \"function\", \"function\": {\"name\": \"python\", \"arguments\": \"{\\\"code\\\": \\\"print(1)\\\\nprint(2)\\\", \\\"timeout_ms\\\": 900000}\"}}]}",
    )
  text
  |> should.equal(
    "[assistant]\n[thinking]\ncheck the flag\n\n[call python]\ncode:\nprint(1)\nprint(2)\ntimeout_ms: 900000",
  )
  string.contains(text, "CAQSjwoKEAgS") |> should.be_false
}

pub fn an_item_with_only_opaque_data_says_so_test() -> Nil {
  let text =
    replay(
      types.Responses,
      "{\"type\": \"reasoning\", \"id\": \"rs_1\", \"encrypted_content\": \"ENCRYPTEDBLOBENCRYPTEDBLOBENCRYPTEDBLOBENCRYPTEDBLOBENCRYPTEDBLOBENCRYPTEDBLOBENCRYPTEDBLOBENCRYPTEDBLOBENCRYPTEDBLOBENCRYPTEDBLOBENCRYPTEDBLOBENCRYPTEDBLOBENCRYPTEDBLOBENCRYPTEDBLOBENCRYPTEDBLOBENCRYPTEDBLOBENCRYPTEDBLOBENCRYPTEDBLOBENCRYPTEDBLOBENCRYPTEDBLOB\", \"summary\": []}",
    )
  string.starts_with(text, "[assistant]\n(provider data only, ")
  |> should.be_true
  string.contains(text, "ENCRYPTEDBLOB") |> should.be_false
}

pub fn arguments_that_are_not_an_object_stay_as_sent_test() -> Nil {
  replay(
    types.Responses,
    "{\"type\": \"function_call\", \"call_id\": \"c1\", \"name\": \"shell\", \"arguments\": \"ls -la\"}",
  )
  |> should.equal("[assistant]\n[call shell]\nls -la")
}

pub fn a_rows_kind_is_its_first_label_word_test() -> Nil {
  search.kind("[user]\nhi") |> should.equal("user")
  search.kind("[user with image/png 1x1]\nhi") |> should.equal("user")
  search.kind("[tool toolu_01]\nout") |> should.equal("tool")
  search.kind("[assistant]\nhello") |> should.equal("assistant")
  search.kind("no label") |> should.equal("")
}
