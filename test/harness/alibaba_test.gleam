import albedo/harness/extension
import albedo/harness/extensions/alibaba/catalog
import albedo/harness/extensions/alibaba/extension as alibaba
import albedo/harness/extensions/antigravity/extension as antigravity
import albedo/harness/extensions/codex/extension as codex
import albedo/harness/extensions/models/extension as models
import albedo/openai_api/types
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should

const mock_catalog = "{\"alibaba-token-plan\":{\"id\":\"alibaba-token-plan\",\"name\":\"Alibaba Token Plan\",\"api\":\"https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1\",\"models\":{\"deepseek-v4.1-flash\":{\"id\":\"deepseek-v4.1-flash\",\"limit\":{\"context\":1000000,\"output\":384000},\"modalities\":{\"input\":[\"text\",\"image\"]},\"reasoning_options\":[{\"type\":\"effort\",\"values\":[\"low\",\"high\",\"max\"]}]},\"qwen3.8-max\":{\"id\":\"qwen3.8-max\",\"limit\":{\"context\":1000000,\"output\":131072},\"modalities\":{\"input\":[\"text\",\"image\",\"video\",\"pdf\"]},\"reasoning_options\":[{\"type\":\"effort\",\"values\":[\"low\",\"medium\",\"xhigh\"]}]}}}}"

pub fn complete_models_fills_missing_fields_from_catalog_test() {
  let #(root, _, home) = fixture()
  let file = write(home, "models.json", mock_catalog)

  let base =
    extension.ModelInfo(
      model: "qwen3.8-max",
      provider: "alibaba",
      context_tokens: None,
      max_context_tokens: None,
      max_output_tokens: None,
      input_modalities: [],
      endpoint: Some(catalog.default_base_url),
      environment: ["ALIBABA_API_KEY"],
      source: "Alibaba Model Studio",
      efforts: [],
    )

  let completed =
    models.complete_models_at(file, [base], catalog.default_base_url)
  let assert [enriched] = completed

  enriched.model |> should.equal("qwen3.8-max")
  enriched.context_tokens |> should.equal(Some(1_000_000))
  enriched.max_output_tokens |> should.equal(Some(131_072))
  enriched.input_modalities
  |> should.equal(["text", "image", "video", "pdf"])
  enriched.efforts |> should.equal(["low", "medium", "xhigh"])

  cleanup(root)
}

pub fn complete_models_preserves_unmatched_model_test() {
  let #(root, _, home) = fixture()
  let file = write(home, "models.json", mock_catalog)

  let base =
    extension.ModelInfo(
      model: "unlisted-new-model",
      provider: "alibaba",
      context_tokens: None,
      max_context_tokens: None,
      max_output_tokens: None,
      input_modalities: ["text"],
      endpoint: Some(catalog.default_base_url),
      environment: ["ALIBABA_API_KEY"],
      source: "Alibaba Model Studio",
      efforts: [],
    )

  let completed =
    models.complete_models_at(file, [base], catalog.default_base_url)
  let assert [unmatched] = completed

  unmatched |> should.equal(base)

  cleanup(root)
}

pub fn catalog_lookup_respects_endpoints_test() {
  let cat = catalog.catalog()

  // Matches default endpoint
  let assert Some(info) = cat.lookup("qwen3.8-max", catalog.default_base_url)
  info.provider |> should.equal("alibaba")
  info.endpoint |> should.equal(Some(catalog.default_base_url))

  // Rejects foreign endpoint like OpenAI
  cat.lookup("qwen3.8-max", "https://api.openai.com/v1") |> should.equal(None)
}

pub fn catalog_list_models_returns_empty_when_no_cache_test() {
  let #(root, _, home) = fixture()
  // When no cache file exists in home, models discovery returns Ok([])
  catalog.models(home, "") |> should.equal(Ok([]))

  // When cached on disk, returns cached ids
  write(home, "alibaba-models.json", "[\"qwen3.8-max\"]")
  catalog.models(home, "") |> should.equal(Ok(["qwen3.8-max"]))

  // Provider filter rejects other providers
  let cat = catalog.catalog()
  cat.list("openai", "") |> should.equal([])

  cleanup(root)
}

pub fn extension_metadata_and_plugins_test() {
  let ext = alibaba.extension()
  ext.name |> should.equal("alibaba")
  ext.requires |> should.equal([])
  list.length(ext.plugins) |> should.equal(2)
}

pub fn alibaba_protocol_enforcement_test() {
  let ext = alibaba.extension()
  // Responses protocol is rejected by Alibaba resolve
  extension.upstream(
    [ext],
    extension.ModelContext(
      "/nonexistent",
      "s1",
      "ali",
      "alibaba",
      "qwen3.8-max",
      types.Responses,
      None,
    ),
  )
  |> should.equal(Error(
    "Alibaba provider requires the chat_completions protocol",
  ))
}

pub fn codex_protocol_enforcement_test() {
  let ext = codex.extension()
  // ChatCompletions protocol is rejected by Codex resolve
  extension.upstream(
    [ext],
    extension.ModelContext(
      "/nonexistent",
      "s1",
      "codex",
      "codex",
      "gpt-5",
      types.ChatCompletions,
      None,
    ),
  )
  |> should.equal(Error("Codex provider requires the responses protocol"))
}

pub fn antigravity_protocol_enforcement_test() {
  let ext = antigravity.extension()
  // Responses protocol is rejected by Antigravity resolve
  extension.upstream(
    [ext],
    extension.ModelContext(
      "/nonexistent",
      "s1",
      "antigravity",
      "antigravity",
      "gemini-3.8-flash",
      types.Responses,
      None,
    ),
  )
  |> should.equal(Error(
    "Antigravity provider requires the chat_completions protocol",
  ))
}

pub fn explain_alibaba_errors_test() {
  alibaba.explain(types.HttpError(401, "unauthorized"))
  |> should.equal(Some(
    "Alibaba Model Studio rejected the API key; check your key or ALIBABA_API_KEY",
  ))

  alibaba.explain(types.HttpError(429, "Allocated quota exceeded"))
  |> should.equal(Some(
    "Alibaba Model Studio rate limit (TPM/TPS) exceeded; wait a few seconds and retry",
  ))

  alibaba.explain(types.HttpError(
    500,
    "{\"error\":{\"message\":\"internal error\"}}",
  ))
  |> should.equal(Some("Alibaba Model Studio error (500): internal error"))
}

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "write")
fn write(base: String, relative: String, content: String) -> String

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil
