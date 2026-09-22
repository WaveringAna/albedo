import albedo/harness/extension
import albedo/harness/models
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

  cleanup(root)
}

pub fn unknown_disputed_and_missing_catalogs_stay_unknown_test() {
  let #(root, _, home) = fixture()
  let file = write(home, "models.json", catalog)

  // Two providers disagree about the same id and no endpoint decides it.
  models.lookup_at(file, "disputed", "") |> should.equal(None)
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
  |> should.equal(extension.ModelInfo(
    "only-openai",
    "openai",
    Some(128_000),
    None,
    [],
    Some("https://api.openai.com/v1"),
    ["OPENAI_API_KEY"],
    info.source,
  ))

  cleanup(root)
}

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "write")
fn write(base: String, relative: String, content: String) -> String

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil

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
