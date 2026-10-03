//// The daemon and the CLI hash a build with one recipe. The shared fixture
//// in test/fixtures/build-digest pins both implementations to the same
//// constant, so a drift on either side fails here and in
//// cli/internal/daemon/build_identity_test.go.

import gleeunit/should

@external(erlang, "albedo_daemon", "tree_digest")
fn tree_digest(path: String) -> String

pub fn tree_digest_matches_the_shared_fixture_test() -> Nil {
  tree_digest("test/fixtures/build-digest")
  |> should.equal(
    "a8f2d0de5c26845d69d69f9a98111ab795b83d4ab24e6f18068b57145c13fe42",
  )
}
