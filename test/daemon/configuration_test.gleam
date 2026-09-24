import albedo/daemon/configuration
import albedo/openai_api/types
import gleam/list
import gleam/result

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "write")
fn write(base: String, relative: String, content: String) -> String

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil

pub fn a_malformed_profile_leaves_the_others_usable_test() {
  let #(root, _, home) = fixture()
  let _ =
    write(
      home,
      "config.json",
      "{\"active\":\"good\",\"providers\":{\"good\":{\"model\":\"m\",\"protocol\":\"responses\"},\"no-model\":{\"protocol\":\"responses\"},\"odd\":{\"model\":\"m\",\"protocol\":\"carrier-pigeon\"}}}",
    )
  let assert Ok(good) = configuration.active(home)
  assert good == configuration.Provider("good", "openai", "m", types.Responses)
  assert configuration.named(home, "good") == Ok(good)
  let assert Error(_) = configuration.named(home, "odd")
  assert configuration.providers(home) == Ok([good])
  let assert Ok(profiles) = configuration.profiles(home)
  assert list.map(profiles, fn(profile) {
      result.map(profile, fn(profile) { profile.name })
      |> result.map_error(fn(error) { error.0 })
    })
    == [Ok("good"), Error("no-model"), Error("odd")]
  cleanup(root)
}
