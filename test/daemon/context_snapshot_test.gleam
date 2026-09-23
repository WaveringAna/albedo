import albedo/daemon/context_snapshot
import albedo/harness/compaction
import albedo/openai_api/types
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

fn observed() -> context_snapshot.Snapshot {
  context_snapshot.ready(
    Some(1234),
    Some("fixture"),
    "fixture-model",
    Some("responses"),
    Some(128_000),
    context_snapshot.compaction(
      Some("rolling"),
      context_snapshot.Compacted,
      Some("recorded by the selected strategy during preparation"),
      Some(10),
      Some(128_000),
      Some(117_200),
      Some("pinned tokenizer estimate"),
      Some(42),
      Some(14),
    ),
    [
      context_snapshot.section(
        "instructions",
        "system instructions",
        context_snapshot.Instructions,
        "albedo core + enabled extension instructions",
        2,
        900,
        "core instructions
enabled extension instructions",
        None,
      ),
      context_snapshot.section(
        "history",
        "prepared conversation",
        context_snapshot.History,
        "durable transcript through rolling compaction",
        14,
        32_100,
        string.repeat("x", 17_000),
        Some("image payload bytes; dimensions and position remain represented"),
      ),
    ],
  )
}

pub fn summary_preserves_order_sources_known_limits_and_bounded_previews_test() {
  let encoded = observed() |> context_snapshot.summary |> json.to_string
  string.contains(encoded, "\"state\":\"ready\"") |> should.be_true
  string.contains(encoded, "\"model\":\"fixture-model\"")
  |> should.be_true
  string.contains(encoded, "\"context_window_tokens\":128000")
  |> should.be_true
  string.contains(encoded, "\"trigger_free_percent\":10")
  |> should.be_true
  string.contains(encoded, "\"estimated_input_tokens\":117200")
  |> should.be_true
  string.contains(encoded, "\"estimate_method\":\"pinned tokenizer estimate\"")
  |> should.be_true
  let assert Ok(#(_, after_instructions)) =
    string.split_once(encoded, "system instructions")
  string.contains(after_instructions, "prepared conversation")
  |> should.be_true
  string.contains(encoded, string.repeat("x", 181)) |> should.be_false
  string.contains(encoded, "image payload bytes") |> should.be_false
}

pub fn page_is_bounded_and_names_intentional_omissions_test() {
  let assert Ok(first) = context_snapshot.page(observed(), "history", 0)
  let first = json.to_string(first)
  string.contains(first, "\"page\":0") |> should.be_true
  string.contains(first, "\"pages\":3") |> should.be_true
  string.contains(first, "image payload bytes") |> should.be_true
  { string.length(first) < 33_000 } |> should.be_true

  let assert Ok(last) = context_snapshot.page(observed(), "history", 2)
  string.contains(json.to_string(last), string.repeat("x", 1000))
  |> should.be_true
  context_snapshot.page(observed(), "history", 3)
  |> should.equal(Error("context page not found"))
  context_snapshot.page(observed(), "missing", 0)
  |> should.equal(Error("context section not found"))
}

pub fn pending_and_unknown_values_are_explicit_without_invented_numbers_test() {
  context_snapshot.pending(
    "runtime session has not prepared a provider request",
  )
  |> context_snapshot.summary
  |> json.to_string
  |> should.equal(
    "{\"state\":\"pending\",\"reason\":\"runtime session has not prepared a provider request\"}",
  )

  let value =
    context_snapshot.ready(
      None,
      None,
      "model",
      None,
      None,
      context_snapshot.compaction(
        None,
        context_snapshot.Unknown,
        None,
        Some(101),
        Some(-1),
        None,
        None,
        None,
        None,
      ),
      [],
    )
    |> context_snapshot.summary
    |> json.to_string
  string.contains(value, "\"status\":\"unknown\"") |> should.be_true
  string.contains(value, "trigger_free_percent") |> should.be_false
  string.contains(value, "input_limit_tokens") |> should.be_false
  string.contains(value, "context_window_tokens") |> should.be_false
}

pub fn exact_request_builder_keeps_source_order_and_omits_payload_bodies_test() {
  let assert Ok(image) =
    types.image("image/png", "c2VjcmV0LWJhc2U2NA==", 2, 3, 13)
  let request =
    types.Request(
      "model",
      Some("system truth"),
      [
        types.User(
          "<extension-context name=\"skills\">\nworkspace data\n</extension-context>",
        ),
        types.UserImage("inspect this", image),
        types.Assistant("seen"),
      ],
      [
        types.Tool(
          "python",
          "run code",
          json.object([#("type", json.string("object"))]),
          True,
        ),
      ],
      None,
    )
  let observation =
    compaction.Observation(
      "fixture",
      "compacted",
      "same request preparation",
      "durable transcript through fixture projection",
      Some(10),
      Some(1000),
      Some(910),
      Some("local byte-based estimate; not provider token usage"),
      Some(20),
      Some(4),
    )
  let snapshot =
    context_snapshot.from_request(
      Some(10),
      "provider",
      "responses",
      types.Responses,
      request,
      Some(observation),
    )
  let encoded = snapshot |> context_snapshot.summary |> json.to_string
  let assert [_, after_instructions] =
    string.split(encoded, "system instructions")
  let assert [_, after_extension] =
    string.split(after_instructions, "extension context · skills")
  let assert [_, after_history] =
    string.split(after_extension, "prepared conversation")
  string.contains(after_history, "tool schemas") |> should.be_true
  string.contains(encoded, "\"trigger_free_percent\":10")
  |> should.be_true
  string.contains(encoded, "\"strategy\":\"fixture\"")
  |> should.be_true
  string.contains(encoded, "not provider token usage") |> should.be_true

  let assert Ok(history_page) = context_snapshot.page(snapshot, "history", 0)
  let history_page = json.to_string(history_page)
  string.contains(history_page, "inspect this") |> should.be_true
  string.contains(history_page, "image/png") |> should.be_true
  string.contains(history_page, "c2VjcmV0LWJhc2U2NA==") |> should.be_false
  string.contains(history_page, "image base64 payload") |> should.be_true
  string.contains(encoded, "durable transcript through fixture projection")
  |> should.be_true

  let assert Ok(tool_page) = context_snapshot.page(snapshot, "tools", 0)
  let tool_page = json.to_string(tool_page)
  string.contains(tool_page, "python") |> should.be_true
  string.contains(tool_page, "run code") |> should.be_true
  string.contains(tool_page, "strict") |> should.be_true
}
