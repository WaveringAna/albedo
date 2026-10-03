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
import sqlight

type EnvRef {
  EnvRef(name: String)
}

type Transport {
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

type Server {
  Server(
    transport: Transport,
    enabled: Bool,
    enabled_tools: Option(List(String)),
    disabled_tools: List(String),
    startup_timeout_ms: Int,
    call_timeout_ms: Int,
  )
}

type Config {
  Config(servers: Dict(String, Server), retry_ms: Int)
}

type Handle

type Definition {
  Definition(name: String, description: String, parameters: Json)
}

const default_retry_ms = 30_000

fn default_config() -> Config {
  Config(dict.new(), default_retry_ms)
}

fn config_decoder() -> decode.Decoder(Config) {
  use servers <- decode.optional_field(
    "servers",
    dict.new(),
    decode.dict(decode.string, server_decoder()),
  )
  use retry_ms <- decode.optional_field("retryMs", default_retry_ms, decode.int)
  decode.success(Config(servers, retry_ms))
}

fn server_decoder() -> decode.Decoder(Server) {
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

fn stdio_decoder() -> decode.Decoder(Transport) {
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

fn http_decoder() -> decode.Decoder(Transport) {
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

fn env_ref_decoder() -> decode.Decoder(EnvRef) {
  decode.map(decode.field("env", decode.string, decode.success), EnvRef)
}

fn load_config() -> Result(Config, String) {
  settings.load("mcp", config_decoder(), default_config())
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
    initialise_catalogues,
  )
}

/// The last catalogue each server answered, under the fingerprint of the
/// setup it answered for. A session opening reads it instead of waiting on
/// the server; one row per server name, so it never outgrows the config.
fn initialise_catalogues(ledger: store.Store) -> Result(Nil, String) {
  store.query(ledger, fn(db) {
    store.exec(
      db,
      "CREATE TABLE IF NOT EXISTS mcp_catalogues(server TEXT PRIMARY KEY,fingerprint TEXT NOT NULL,catalogue BLOB NOT NULL);",
    )
  })
}

fn saved_catalogue(
  ledger: store.Store,
  server: String,
  fingerprint: String,
) -> Option(BitArray) {
  store.read(
    ledger,
    "SELECT catalogue FROM mcp_catalogues WHERE server=? AND fingerprint=?",
    [sqlight.text(server), sqlight.text(fingerprint)],
    decode.at([0], decode.bit_array),
  )
  |> result.unwrap([])
  |> list.first
  |> option.from_result
}

fn save_catalogue(
  ledger: store.Store,
  server: String,
  fingerprint: String,
  catalogue: BitArray,
) -> Nil {
  let _ =
    store.write(
      ledger,
      "INSERT OR REPLACE INTO mcp_catalogues(server,fingerprint,catalogue) VALUES(?,?,?)",
      [sqlight.text(server), sqlight.text(fingerprint), sqlight.blob(catalogue)],
    )
  Nil
}

fn prepare(
  config: Config,
  ledger: store.Store,
  session: String,
  _workspace: String,
) -> Result(extension.Managed, String) {
  use handle <- result.try(
    native_prepare(
      encode_config(config),
      ledger,
      session,
      fn(server, fingerprint) { saved_catalogue(ledger, server, fingerprint) },
      fn(server, fingerprint, catalogue) {
        save_catalogue(ledger, server, fingerprint, catalogue)
      },
    ),
  )
  case decode_definitions(native_definitions(handle)) {
    Error(error) -> {
      native_close(handle)
      Error(error)
    }
    Ok(definitions) ->
      Ok(
        extension.Managed(
          ..extension.empty(),
          context: native_context(handle),
          instructions: "MCP tool calls may have side effects. Never retry a failed or interrupted MCP call without first inspecting its effects; transport loss means the outcome is unknown.",
          tools: list.map(definitions, fn(definition) {
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
                |> result.map_error(extension.Refused)
              },
              fn(_) { None },
            )
          }),
          warnings: list.map(native_offline(handle), fn(name) {
            "MCP server '"
            <> name
            <> "' is unavailable; its tools join the session once it connects"
          }),
          observe: fn(session: extension.Session, event) {
            case event {
              extension.Stirred ->
                native_observe(handle, False, session.refresh)
              extension.TurnEnded(_) ->
                native_observe(handle, True, session.refresh)
              _ -> Nil
            }
          },
          close: fn() { native_close(handle) },
        ),
      )
  }
}

fn decode_definitions(value: String) -> Result(List(Definition), String) {
  json.parse(value, decode.list(definition_decoder()))
  |> result.replace_error("MCP discovery returned invalid tool definitions")
}

fn definition_decoder() -> decode.Decoder(Definition) {
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
    #("retryMs", json.int(config.retry_ms)),
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
fn native_prepare(
  config: String,
  ledger: store.Store,
  session: String,
  saved: fn(String, String) -> Option(BitArray),
  save: fn(String, String, BitArray) -> Nil,
) -> Result(Handle, String)

@external(erlang, "albedo_mcp", "definitions")
fn native_definitions(handle: Handle) -> String

@external(erlang, "albedo_mcp", "context")
fn native_context(handle: Handle) -> String

@external(erlang, "albedo_mcp", "offline")
fn native_offline(handle: Handle) -> List(String)

@external(erlang, "albedo_mcp", "observe")
fn native_observe(
  handle: Handle,
  turn_ended: Bool,
  refresh: fn(String) -> Nil,
) -> Nil

@external(erlang, "albedo_mcp", "call")
fn native_call(
  handle: Handle,
  name: String,
  arguments: String,
) -> Result(String, String)

@external(erlang, "albedo_mcp", "close")
fn native_close(handle: Handle) -> Nil
