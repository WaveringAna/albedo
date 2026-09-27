// Private regular-file validation guards symlink and permissions attacks on MCP credentials.
import gleam/dynamic
import gleeunit/should

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "write")
fn write(base: String, path: String, contents: String) -> String

@external(erlang, "albedo_skills_test_support", "chmod")
fn chmod(base: String, path: String, mode: Int) -> Nil

@external(erlang, "albedo_skills_test_support", "replace_with_symlink")
fn link(base: String, source: String, path: String) -> Nil

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil

@external(erlang, "albedo_mcp_credentials", "server_at")
fn secret(home: String, name: String) -> Result(dynamic.Dynamic, String)

pub fn credentials_require_private_regular_file_test() {
  let #(root, _, home) = fixture()
  secret(home, "docs") |> should.be_ok
  let _ =
    write(
      home,
      "mcp-credentials.json",
      "{\"servers\":{\"docs\":{\"bearerToken\":\"never-log\"}}}",
    )
  chmod(home, "mcp-credentials.json", 420)
  secret(home, "docs") |> should.be_error
  chmod(home, "mcp-credentials.json", 384)
  secret(home, "docs") |> should.be_ok
  let _ = write(home, "replacement", "{}")
  link(home, "replacement", "mcp-credentials.json")
  secret(home, "docs") |> should.be_error
  cleanup(root)
}
