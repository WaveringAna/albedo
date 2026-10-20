// An https MCP server is verified against the OS trust store albedo's other
// HTTP clients use, not the certifi bundle hackney ships. E2E cannot tell the
// two apart without a CA that one trusts and the other does not.
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleeunit/should

@external(erlang, "albedo_mcp", "transport_spec")
fn transport_spec(
  config: dict.Dict(String, String),
  secrets: dict.Dict(String, String),
  spec: dict.Dict(String, String),
) -> Dynamic

@external(erlang, "maps", "get")
fn map_get(key: Atom, map: Dynamic) -> Dynamic

@external(erlang, "proplists", "get_value")
fn property(key: Atom, list: Dynamic) -> Dynamic

@external(erlang, "public_key", "cacerts_get")
fn system_store() -> Dynamic

pub fn mcp_https_uses_the_system_trust_store_test() -> Nil {
  let config =
    dict.from_list([#("type", "http"), #("url", "https://mcp.example.com/mcp")])
  let tls =
    transport_spec(config, dict.new(), dict.new())
    |> map_get(atom.create("ssl_options"), _)
  property(atom.create("cacerts"), tls) |> should.equal(system_store())
  property(atom.create("verify"), tls)
  |> decode.run(atom.decoder())
  |> should.equal(Ok(atom.create("verify_peer")))
}
