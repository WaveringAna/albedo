// MCP URL validation blocks embedded credentials and unsupported schemes even on trusted networks.
import gleeunit/should

@external(erlang, "albedo_mcp", "url_allowed")
fn allowed(url: String) -> Bool

pub fn mcp_http_trusted_network_test() -> Nil {
  allowed("http://100.64.0.19:8787/mcp") |> should.be_true
  allowed("http://nas.lan:8787/mcp") |> should.be_true
  allowed("https://mcp.example.com/mcp") |> should.be_true
  allowed("http://127.0.0.1:8787/mcp") |> should.be_true
}

pub fn mcp_url_rejects_embedded_credentials_and_invalid_schemes_test() -> Nil {
  allowed("http://user:secret@nas.lan/mcp") |> should.be_false
  allowed("http://nas.lan/mcp#fragment") |> should.be_false
  allowed("file:///tmp/server") |> should.be_false
  allowed("http:///missing-host") |> should.be_false
}
