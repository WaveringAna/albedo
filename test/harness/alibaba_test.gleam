import albedo/harness/extension
import albedo/harness/extensions/alibaba/catalog
import albedo/harness/extensions/alibaba/extension as alibaba
import albedo/harness/extensions/antigravity/extension as antigravity
import albedo/harness/extensions/codex/extension as codex
import albedo/openai_api/types
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should

pub fn known_models_contain_expected_chat_models_test() {
  let ids = list.map(catalog.known(), fn(m) { m.id })
  list.contains(ids, "deepseek-v4.1-flash") |> should.be_true
  list.contains(ids, "deepseek-v4-pro") |> should.be_true
  list.contains(ids, "deepseek-v4-flash-0731") |> should.be_true
  list.contains(ids, "glm-5.2") |> should.be_true
  list.contains(ids, "glm-5.3") |> should.be_true
  list.contains(ids, "qwen3.6-flash") |> should.be_true
  list.contains(ids, "qwen3.7-max") |> should.be_true
  list.contains(ids, "qwen3.7-plus") |> should.be_true
  list.contains(ids, "qwen3.8-flash") |> should.be_true
  list.contains(ids, "qwen3.8-max") |> should.be_true
}

pub fn reasoning_efforts_match_family_capabilities_test() {
  // DeepSeek models expose the full effort ladder
  let ds = catalog.hint("deepseek-v4.1-flash")
  ds.efforts |> should.equal(["low", "medium", "high", "xhigh", "max"])

  // GLM-5.3 accepts only low/high/max
  let glm53 = catalog.hint("glm-5.3")
  glm53.efforts |> should.equal(["low", "high", "max"])

  // GLM-5.2 accepts the full effort ladder
  let glm52 = catalog.hint("glm-5.2")
  glm52.efforts |> should.equal(["low", "medium", "high", "xhigh", "max"])

  // Qwen models have no effort parameter on Model Studio chat completions
  let qwen = catalog.hint("qwen3.8-max")
  qwen.efforts |> should.equal([])
}

pub fn catalog_lookup_respects_endpoints_test() {
  let cat = catalog.catalog()

  // Matches default endpoint
  let assert Some(info) = cat.lookup("qwen3.8-max", catalog.default_base_url)
  info.provider |> should.equal("alibaba")
  info.context_tokens |> should.equal(Some(1_000_000))
  info.max_output_tokens |> should.equal(Some(131_072))
  info.input_modalities |> should.equal(["text", "image"])
  info.efforts |> should.equal([])

  // Matches empty endpoint for Alibaba model
  let assert Some(ds_info) = cat.lookup("deepseek-v4-pro", "")
  ds_info.efforts |> should.equal(["low", "medium", "high", "xhigh", "max"])

  // Rejects foreign endpoint like OpenAI
  cat.lookup("qwen3.8-max", "https://api.openai.com/v1") |> should.equal(None)
}

pub fn catalog_list_models_returns_alibaba_ids_test() {
  let cat = catalog.catalog()
  let models = cat.list("alibaba", "")
  list.contains(models, "qwen3.8-max") |> should.be_true
  list.contains(models, "deepseek-v4.1-flash") |> should.be_true
  list.contains(models, "glm-5.3") |> should.be_true

  // Does not answer for other providers
  cat.list("openai", "") |> should.equal([])
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
