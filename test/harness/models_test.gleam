import albedo/harness/extension
import albedo/harness/extensions/models/extension as models
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

const catalog = "{\"openai\":{\"id\":\"openai\",\"name\":\"OpenAI\",\"api\":\"https://api.openai.com/v1\",\"env\":[\"OPENAI_API_KEY\"],\"models\":{\"shared-model\":{\"id\":\"shared-model\",\"limit\":{\"context\":400000,\"output\":128000},\"modalities\":{\"input\":[\"text\",\"image\"]}},\"only-openai\":{\"id\":\"only-openai\",\"limit\":{\"context\":128000}}}},\"mirror\":{\"id\":\"mirror\",\"name\":\"Mirror\",\"api\":\"https://mirror.example.com/v1\",\"models\":{\"shared-model\":{\"id\":\"shared-model\",\"limit\":{\"context\":400000,\"output\":128000}},\"disputed\":{\"id\":\"disputed\",\"limit\":{\"context\":8000}},\"vendor/qualified\":{\"id\":\"vendor/qualified\",\"limit\":{\"context\":32000}}}},\"other\":{\"id\":\"other\",\"name\":\"Other\",\"api\":\"https://other.example.com/v1\",\"models\":{\"disputed\":{\"id\":\"disputed\",\"limit\":{\"context\":16000}}}}}"

pub fn endpoint_selects_between_providers_publishing_one_model_test() {
  let #(root, _, home) = fixture()
  let file = write(home, "models.json", catalog)

  let assert Some(info) =
    models.lookup_at(file, "shared-model", "https://mirror.example.com/v1")
  info.provider |> should.equal("mirror")
  info.context_tokens |> should.equal(Some(400_000))
  string.contains(info.source, "provider endpoint") |> should.be_true

  let assert Some(agreed) = models.lookup_at(file, "shared-model", "")
  agreed.context_tokens |> should.equal(Some(400_000))
  string.contains(agreed.source, "model id") |> should.be_true
  // No endpoint names who serves it, so no provider is guessed.
  agreed.provider |> should.equal("")
  agreed.endpoint |> should.equal(None)
  // A provider that reports no input kinds does not veto the others'.
  agreed.input_modalities |> should.equal(["text", "image"])

  cleanup(root)
}

/// A gateway the catalog does not list serves a model several providers
/// publish with different limits: the smallest limits and the input kinds
/// every provider reports answer.
pub fn disputed_limits_answer_with_the_smallest_test() {
  let #(root, _, home) = fixture()
  let file = write(home, "models.json", catalog)

  let assert Some(disputed) =
    models.lookup_at(file, "disputed", "https://gateway.example.com/v1")
  disputed.provider |> should.equal("")
  disputed.context_tokens |> should.equal(Some(8000))
  string.contains(disputed.source, "smallest limits of 2 providers")
  |> should.be_true
  // An endpoint that names a provider still takes that provider's limits.
  let assert Some(other) =
    models.lookup_at(file, "disputed", "https://other.example.com/v1")
  other.provider |> should.equal("other")
  other.context_tokens |> should.equal(Some(16_000))

  cleanup(root)
}

pub fn provider_scoped_lookup_keeps_metadata_with_its_provider_test() {
  let #(root, _, home) = fixture()
  let file = write(home, "models.json", catalog)
  let assert Some(info) =
    models.lookup_provider_at(file, "mirror", "shared-model")
  assert info.provider == "mirror"
  assert info.context_tokens == Some(400_000)
  assert info.source
    == "models.dev catalog cached at " <> file <> "; matched by provider name"
  assert models.lookup_provider_at(file, "openai", "disputed") == None
  assert models.lookup_provider_at(file, "mirror", "disputed") != None
  cleanup(root)
}

pub fn unknown_and_missing_catalogs_stay_unknown_test() {
  let #(root, _, home) = fixture()
  let file = write(home, "models.json", catalog)

  models.lookup_at(file, "absent-model", "") |> should.equal(None)
  models.lookup_at(home <> "/missing.json", "shared-model", "")
  |> should.equal(None)
  let broken = write(home, "broken.json", "{not json")
  models.lookup_at(broken, "shared-model", "") |> should.equal(None)

  cleanup(root)
}

pub fn catalog_answers_qualified_and_unqualified_ids_test() {
  let #(root, _, home) = fixture()
  let file = write(home, "models.json", catalog)

  let assert Some(qualified) = models.lookup_at(file, "vendor/qualified", "")
  qualified.context_tokens |> should.equal(Some(32_000))
  let assert Some(short) = models.lookup_at(file, "qualified", "")
  short.model |> should.equal("vendor/qualified")

  let assert Some(info) =
    models.lookup_at(file, "only-openai", "https://api.openai.com/v1")
  info
  |> should.equal(
    extension.ModelInfo(
      "only-openai",
      "openai",
      Some(128_000),
      None,
      [],
      Some("https://api.openai.com/v1"),
      ["OPENAI_API_KEY"],
      info.source,
      [],
    ),
  )

  cleanup(root)
}

/// A catalog cached before trimming existed: names, prices and dates albedo
/// never reads. The first lookup rewrites it with only what lookup reads.
pub fn a_full_catalog_is_trimmed_in_place_without_changing_answers_test() {
  let #(root, _, home) = fixture()
  let full =
    string.replace(
      catalog,
      "\"limit\":",
      "\"cost\":{\"input\":1.5},\"release_date\":\"2026-01-01\",\"limit\":",
    )
  let file = write(home, "models.json", full)

  let assert Some(info) =
    models.lookup_at(file, "shared-model", "https://mirror.example.com/v1")
  info.context_tokens |> should.equal(Some(400_000))

  let assert Ok(trimmed) = read(file)
  string.contains(trimmed, "\"name\"") |> should.be_false
  string.contains(trimmed, "cost") |> should.be_false
  { string.byte_size(trimmed) < string.byte_size(full) } |> should.be_true
  // The rewritten file answers exactly as the original did.
  let assert Some(again) =
    models.lookup_at(file, "shared-model", "https://mirror.example.com/v1")
  again |> should.equal(info)
  let assert Some(disputed) = models.lookup_at(file, "disputed", "")
  disputed.context_tokens |> should.equal(Some(8000))
  models.list_at(file, "openai", "")
  |> should.equal(["only-openai", "shared-model"])

  cleanup(root)
}

pub fn a_fetched_catalog_is_stored_trimmed_test() {
  let #(root, _, home) = fixture()
  let file = home <> "/models.json"
  models.reload_at(file, serve_once(catalog)) |> should.equal(Ok(Nil))
  let assert Ok(stored) = read(file)
  string.contains(stored, "\"name\"") |> should.be_false
  let assert Some(info) = models.lookup_at(file, "vendor/qualified", "")
  info.context_tokens |> should.equal(Some(32_000))
  cleanup(root)
}

@external(erlang, "file", "read_file")
fn read(path: String) -> Result(String, a)

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "write")
fn write(base: String, relative: String, content: String) -> String

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil

@external(erlang, "albedo_skills_test_support", "serve_once")
fn serve_once(body: String) -> String

pub fn explicit_reload_replaces_the_cache_before_returning_test() {
  let #(root, _, home) = fixture()
  let file = home <> "/models.json"
  let endpoint = serve_once(catalog)

  models.reload_at(file, endpoint) |> should.equal(Ok(Nil))
  models.list_at(file, "openai", "")
  |> should.equal(["only-openai", "shared-model"])

  cleanup(root)
}

pub fn explicit_reload_rejects_unsafe_urls_test() {
  let #(root, _, home) = fixture()
  models.reload_at(home <> "/models.json", "http://models.dev/api.json")
  |> should.equal(Error("models catalog URL must use https or loopback http"))
  cleanup(root)
}

pub fn catalog_lists_provider_models_without_inventing_unknowns_test() {
  let #(root, _, home) = fixture()
  let file = write(home, "models.json", catalog)
  models.list_at(file, "openai", "")
  |> should.equal(["only-openai", "shared-model"])
  models.list_at(file, "", "https://mirror.example.com/v1")
  |> should.equal(["disputed", "shared-model", "vendor/qualified"])
  models.list_at(file, "openai", "https://mirror.example.com/v1")
  |> should.equal(["disputed", "shared-model", "vendor/qualified"])
  models.list_at(file, "missing", "") |> should.equal([])
  cleanup(root)
}

pub fn catalog_lookup_decodes_reasoning_efforts_test() {
  let #(root, _, home) = fixture()
  let reasoning_catalog =
    "{\"reasoner\":{\"id\":\"reasoner\",\"name\":\"Reasoner\",\"api\":\"https://reasoner.example.com/v1\",\"models\":{\"smart-model\":{\"id\":\"smart-model\",\"limit\":{\"context\":200000,\"output\":64000},\"reasoning_options\":[{\"type\":\"toggle\"},{\"type\":\"effort\",\"values\":[\"low\",\"high\",\"max\"]}]}}}}"
  let file = write(home, "models.json", reasoning_catalog)

  let assert Some(info) =
    models.lookup_at(file, "smart-model", "https://reasoner.example.com/v1")
  info.efforts |> should.equal(["low", "high", "max"])

  // Also test complete_model
  let base =
    extension.ModelInfo(
      model: "smart-model",
      provider: "reasoner",
      context_tokens: None,
      max_output_tokens: None,
      input_modalities: [],
      endpoint: Some("https://reasoner.example.com/v1"),
      environment: [],
      source: "Reasoner",
      efforts: [],
    )
  let assert [completed] =
    models.complete_models_at(file, [base], "https://reasoner.example.com/v1")
  completed.context_tokens |> should.equal(Some(200_000))
  completed.max_output_tokens |> should.equal(Some(64_000))
  completed.efforts |> should.equal(["low", "high", "max"])

  cleanup(root)
}
