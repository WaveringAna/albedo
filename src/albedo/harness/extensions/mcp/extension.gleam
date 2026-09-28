//// Session-owned MCP clients and dynamically discovered capabilities.

import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/settings
import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub type EnvRef {
  EnvRef(name: String)
}

pub type Transport {
  Stdio(
    command: String,
    arguments: List(String),
    cwd: Option(String),
    environment: Dict(String, EnvRef),
  )
  Http(
    url: String,
    headers: Dict(String, EnvRef),
    bearer_token_env_var: Option(String),
  )
}

pub type Server {
  Server(
    transport: Transport,
    enabled: Bool,
    enabled_tools: Option(List(String)),
    disabled_tools: List(String),
    startup_timeout_ms: Int,
    call_timeout_ms: Int,
  )
}

pub type Config {
  Config(servers: Dict(String, Server))
}

pub type Handle

type Definition {
  Definition(name: String, description: String, parameters: Json)
}

pub fn default_config() -> Config {
  Config(dict.new())
}

pub fn config_decoder() {
  use servers <- decode.optional_field(
    "servers",
    dict.new(),
    decode.dict(decode.string, server_decoder()),
  )
  decode.success(Config(servers))
}

fn server_decoder() {
  use kind <- decode.field("type", decode.string)
  use enabled <- decode.optional_field("enabled", True, decode.bool)
  use enabled_tools <- decode.optional_field(
    "enabledTools",
    None,
    decode.optional(decode.list(decode.string)),
  )
  use disabled_tools <- decode.optional_field(
    "disabledTools",
    [],
    decode.list(decode.string),
  )
  use startup <- decode.optional_field("startupTimeoutMs", 20_000, decode.int)
  use call <- decode.optional_field("callTimeoutMs", 60_000, decode.int)
  case kind {
    "stdio" -> stdio_decoder()
    "http" -> http_decoder()
    _ -> decode.failure(Stdio("", [], None, dict.new()), "MCP transport type")
  }
  |> decode.then(fn(transport) {
    let server =
      Server(transport, enabled, enabled_tools, disabled_tools, startup, call)
    case startup > 0 && startup <= 3_600_000 && call > 0 && call <= 3_600_000 {
      True -> decode.success(server)
      False -> decode.failure(server, "positive MCP timeouts")
    }
  })
}

fn stdio_decoder() {
  use command <- decode.field("command", decode.string)
  use arguments <- decode.optional_field("args", [], decode.list(decode.string))
  use cwd <- decode.optional_field("cwd", None, decode.optional(decode.string))
  use environment <- decode.optional_field(
    "env",
    dict.new(),
    decode.dict(decode.string, env_ref_decoder()),
  )
  decode.success(Stdio(command, arguments, cwd, environment))
}

fn http_decoder() {
  use url <- decode.field("url", decode.string)
  use headers <- decode.optional_field(
    "headers",
    dict.new(),
    decode.dict(decode.string, env_ref_decoder()),
  )
  use bearer <- decode.optional_field(
    "bearerTokenEnvVar",
    None,
    decode.optional(decode.string),
  )
  decode.success(Http(url, headers, bearer))
}

fn env_ref_decoder() {
  decode.map(decode.field("env", decode.string, decode.success), EnvRef)
}

pub fn load_config() -> Result(Config, String) {
  settings.load("mcp", config_decoder(), default_config())
}

pub fn extension(config: Config) -> extension.Extension {
  bundle(fn() { Ok(config) })
}

pub fn configured_extension() -> extension.Extension {
  bundle(load_config)
}

fn bundle(resolve: fn() -> Result(Config, String)) -> extension.Extension {
  extension.Extension(
    "mcp",
    "Model Context Protocol servers with session-owned connections",
    [],
    [
      extension.ManagedPlugin(fn(ledger, session, workspace) {
        use config <- result.try(resolve())
        prepare(config, ledger, session, workspace)
      }),
    ],
    extension.no_initialise,
  )
}

fn prepare(
  config: Config,
  _ledger: store.Store,
  session: String,
  _workspace: String,
) -> Result(extension.Managed, String) {
  use handle <- result.try(native_prepare(encode_config(config), session))
  case decode_definitions(native_definitions(handle)) {
    Error(error) -> {
      native_close(handle)
      Error(error)
    }
    Ok(definitions) ->
      Ok(
        extension.Managed(
          native_context(handle),
          "MCP tool calls may have side effects. Never retry a failed or interrupted MCP call without first inspecting its effects; transport loss means the outcome is unknown.",
          list.map(definitions, fn(definition) {
            extension.Tool(
              types.Tool(
                definition.name,
                definition.description,
                definition.parameters,
                False,
              ),
              fn(_, arguments) {
                native_call(handle, definition.name, arguments)
                |> result.map(extension.text)
              },
              fn(_) { None },
            )
          }),
          [],
          [],
          [],
          fn() { native_close(handle) },
        ),
      )
  }
}

fn decode_definitions(value: String) -> Result(List(Definition), String) {
  json.parse(value, decode.list(definition_decoder()))
  |> result.replace_error("MCP discovery returned invalid tool definitions")
}

fn definition_decoder() {
  use name <- decode.field("name", decode.string)
  use description <- decode.field("description", decode.string)
  use parameters <- decode.field("parameters", decode.dynamic)
  decode.success(Definition(name, description, types.encode_value(parameters)))
}

fn encode_config(config: Config) -> String {
  json.object([
    #(
      "servers",
      json.object(
        config.servers
        |> dict.to_list
        |> list.map(fn(entry) { #(entry.0, encode_server(entry.1)) }),
      ),
    ),
  ])
  |> json.to_string
}

fn encode_server(server: Server) -> Json {
  let common = [
    #("enabled", json.bool(server.enabled)),
    #("disabledTools", json.array(server.disabled_tools, json.string)),
    #("startupTimeoutMs", json.int(server.startup_timeout_ms)),
    #("callTimeoutMs", json.int(server.call_timeout_ms)),
  ]
  let common = case server.enabled_tools {
    None -> common
    Some(values) -> [
      #("enabledTools", json.array(values, json.string)),
      ..common
    ]
  }
  case server.transport {
    Stdio(command, arguments, cwd, environment) ->
      json.object([
        #("type", json.string("stdio")),
        #("command", json.string(command)),
        #("args", json.array(arguments, json.string)),
        #("cwd", json.nullable(cwd, json.string)),
        #("env", encode_refs(environment)),
        ..common
      ])
    Http(url, headers, bearer) ->
      json.object([
        #("type", json.string("http")),
        #("url", json.string(url)),
        #("headers", encode_refs(headers)),
        #("bearerTokenEnvVar", json.nullable(bearer, json.string)),
        ..common
      ])
  }
}

fn encode_refs(values: Dict(String, EnvRef)) -> Json {
  values
  |> dict.to_list
  |> list.map(fn(entry) {
    #(entry.0, json.object([#("env", json.string(entry.1.name))]))
  })
  |> json.object
}

@external(erlang, "albedo_mcp", "prepare")
fn native_prepare(config: String, session: String) -> Result(Handle, String)

@external(erlang, "albedo_mcp", "definitions")
fn native_definitions(handle: Handle) -> String

@external(erlang, "albedo_mcp", "context")
fn native_context(handle: Handle) -> String

@external(erlang, "albedo_mcp", "call")
fn native_call(
  handle: Handle,
  name: String,
  arguments: String,
) -> Result(String, String)

@external(erlang, "albedo_mcp", "close")
fn native_close(handle: Handle) -> Nil
