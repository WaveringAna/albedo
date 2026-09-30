// Disputed catalog model limits must resolve conservatively across providers with the same model ID.
import albedo/harness/extensions/models/extension as models
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

const catalog = "{\"openai\":{\"id\":\"openai\",\"name\":\"OpenAI\",\"api\":\"https://api.openai.com/v1\",\"env\":[\"OPENAI_API_KEY\"],\"models\":{\"shared-model\":{\"id\":\"shared-model\",\"limit\":{\"context\":400000,\"output\":128000},\"modalities\":{\"input\":[\"text\",\"image\"]}},\"only-openai\":{\"id\":\"only-openai\",\"limit\":{\"context\":128000}}}},\"mirror\":{\"id\":\"mirror\",\"name\":\"Mirror\",\"api\":\"https://mirror.example.com/v1\",\"models\":{\"shared-model\":{\"id\":\"shared-model\",\"limit\":{\"context\":400000,\"output\":128000}},\"disputed\":{\"id\":\"disputed\",\"limit\":{\"context\":8000}},\"vendor/qualified\":{\"id\":\"vendor/qualified\",\"limit\":{\"context\":32000}}}},\"other\":{\"id\":\"other\",\"name\":\"Other\",\"api\":\"https://other.example.com/v1\",\"models\":{\"disputed\":{\"id\":\"disputed\",\"limit\":{\"context\":16000}}}}}"

pub fn disputed_limits_answer_with_the_smallest_test() {
  let #(root, _, home) = fixture()
  let file = write(home, "models.json", catalog)

  let assert Some(disputed) =
    models.lookup_at(file, "disputed", Some("https://gateway.example.com/v1"))
  disputed.provider |> should.equal("")
  disputed.context_tokens |> should.equal(Some(8000))
  string.contains(disputed.source, "smallest limits of 2 providers")
  |> should.be_true
  // An endpoint that names a provider still takes that provider's limits.
  let assert Some(other) =
    models.lookup_at(file, "disputed", Some("https://other.example.com/v1"))
  other.provider |> should.equal("other")
  other.context_tokens |> should.equal(Some(16_000))

  cleanup(root)
}

pub fn lookup_with_none_endpoint_test() {
  let #(root, _, home) = fixture()
  let file = write(home, "models.json", catalog)

  let assert Some(disputed) = models.lookup_at(file, "disputed", None)
  disputed.provider |> should.equal("")
  disputed.context_tokens |> should.equal(Some(8000))

  cleanup(root)
}

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "write")
fn write(base: String, relative: String, content: String) -> String

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil
