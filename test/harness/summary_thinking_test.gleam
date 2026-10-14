//// The summarizer reads the reasoning a model showed: an agent's decisions
//// are often written only in its thinking. Encrypted reasoning and
//// signatures never reach it.

import albedo/harness/compaction
import albedo/openai_api/types
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should

fn replay(protocol: types.Protocol, body: String) -> types.Input {
  let assert Ok(item) = json.parse(body, types.replay_decoder(protocol))
  types.Replay(item)
}

fn reads(input: types.Input, shown: List(String), hidden: List(String)) -> Nil {
  let text = compaction.render_summary_input(input)
  should.be_true(string.contains(text, "[assistant thinking]"))
  list.each(shown, fn(part) { should.be_true(string.contains(text, part)) })
  list.each(hidden, fn(part) { should.be_false(string.contains(text, part)) })
}

pub fn claude_thinking_reaches_the_summarizer_test() -> Nil {
  replay(
    types.ChatCompletions,
    "{\"role\":\"assistant\",\"content\":\"\",\"reasoning_content\":\"stdlib keys stay @runtime\",\"reasoning_details\":[{\"type\":\"claude.blocks\",\"model\":\"claude\",\"blocks\":[{\"type\":\"thinking\",\"thinking\":\"stdlib keys stay @runtime\",\"signature\":\"SIGNED-BLOB\"}]}],\"tool_calls\":[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"python\",\"arguments\":\"{}\"}}]}",
  )
  |> reads(["stdlib keys stay @runtime", "[assistant call python]"], [
    "SIGNED-BLOB",
  ])
}

pub fn gemini_thoughts_reach_the_summarizer_test() -> Nil {
  replay(
    types.ChatCompletions,
    "{\"role\":\"assistant\",\"content\":null,\"reasoning_content\":\"relative module paths resolve against the base dir\",\"reasoning_details\":[{\"type\":\"antigravity.parts\",\"index\":0,\"model\":\"gemini\",\"parts\":[{\"thought\":true,\"text\":\"relative module paths resolve against the base dir\",\"thoughtSignature\":\"THOUGHT-SIGNATURE\"}]}]}",
  )
  |> reads(["relative module paths resolve against the base dir"], [
    "THOUGHT-SIGNATURE",
  ])
}

pub fn a_responses_reasoning_summary_reaches_the_summarizer_test() -> Nil {
  replay(
    types.Responses,
    "{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"ENCRYPTED\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"**CLI overrides the env var**\"}]}",
  )
  |> reads(["**CLI overrides the env var**"], ["ENCRYPTED"])
}

pub fn encrypted_only_reasoning_contributes_nothing_test() -> Nil {
  replay(
    types.Responses,
    "{\"type\":\"reasoning\",\"id\":\"rs_2\",\"encrypted_content\":\"ENCRYPTED\",\"summary\":[]}",
  )
  |> compaction.render_summary_input
  |> should.equal("")
}
