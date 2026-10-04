//// Protocol 3 HTTP admission and wire values. Domain owners decide effects;
//// this module validates client syntax and encodes bounded HTTP responses.

import albedo/harness/location
import albedo/harness/ssh
import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http.{Patch}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mist

/// Canonical cached host facts, shared by core and extension resources.
pub fn host(observation: ssh.Observation) -> json.Json {
  json.object([
    #("target", json.string(observation.target)),
    #("state", json.string(observation.state)),
    #("detail", json.nullable(observation.detail, reason(observation.state, _))),
    #("observed_at", json.null()),
    #(
      "os",
      json.nullable(
        option.map(observation.host, fn(host) { host.os }),
        json.string,
      ),
    ),
    #(
      "architecture",
      json.nullable(
        option.map(observation.host, fn(host) { host.arch }),
        json.string,
      ),
    ),
    #(
      "home",
      json.nullable(
        option.map(observation.host, fn(host) { host.home }),
        json.string,
      ),
    ),
    #("authentication", case observation.control {
      Some(control) ->
        json.object([
          #(
            "instructions",
            json.string(
              "Authenticate this SSH target in a terminal, then start a new probe.",
            ),
          ),
          #("ssh_target", json.string(observation.target)),
          #("control_path", json.string(control)),
        ])
      None -> json.null()
    }),
  ])
}

pub const ordinary_body_limit = 65_536

pub const input_body_limit = 9_200_000

pub const response_limit = 1_048_576

pub type Failure {
  Failure(status: Int, code: String, detail: String)
}

pub type Creation {
  NewSession(
    workspace: String,
    name: Option(String),
    provider_profile: Option(String),
    model: Option(String),
    effort: Option(String),
  )
  ForkSession(
    source_session_id: String,
    checkpoint_id: String,
    name: Option(String),
  )
  ChildSession(
    parent_id: String,
    address: String,
    name: String,
    initial_input_id: String,
    task: String,
    model: Option(String),
    effort: Option(String),
  )
}

pub type ImageUpload {
  ImageUpload(mime_type: String, data: String)
}

pub type Input {
  MessageInput(
    text: String,
    image: Option(ImageUpload),
    client_id: Option(String),
  )
  ContinueInput(client_id: Option(String))
  SkillInput(
    candidate_id: String,
    catalog_revision: String,
    arguments: String,
    client_id: Option(String),
  )
  CommandInput(
    command_id: String,
    arguments: Dynamic,
    client_id: Option(String),
  )
}

pub type Interrupt {
  Interrupt(run_id: Option(String), through_input_order: Int)
}

pub fn problem(failure: Failure) -> json.Json {
  json.object([
    #("type", json.string("about:blank")),
    #("title", json.string(failure.code)),
    #("status", json.int(failure.status)),
    #("detail", json.string(failure.detail)),
    #("code", json.string(failure.code)),
  ])
}

pub fn fail(failure: Failure) -> response.Response(mist.ResponseData) {
  reply(failure.status, problem(failure))
  |> response.set_header("content-type", "application/problem+json")
}

pub fn reply(
  status: Int,
  value: json.Json,
) -> response.Response(mist.ResponseData) {
  raw(status, json.to_string(value))
}

pub fn raw(
  status: Int,
  encoded: String,
) -> response.Response(mist.ResponseData) {
  case string.byte_size(encoded) > response_limit {
    True ->
      fail(Failure(
        503,
        "response_limit",
        "response exceeds its encoded byte limit",
      ))
    False ->
      response.new(status)
      |> response.set_header("content-type", "application/json")
      |> response.set_header("cache-control", "no-store")
      |> response.set_body(mist.Bytes(bytes_tree.from_string(encoded)))
  }
}

pub fn invalid(detail: String) -> Failure {
  Failure(400, "invalid_request", detail)
}

pub fn reason(code: String, detail: String) -> json.Json {
  json.object([
    #("code", json.string(code)),
    #("detail", json.string(scalar_prefix(detail, 4096))),
  ])
}

@external(erlang, "albedo_http_api", "parse")
fn strict_json(bytes: BitArray) -> Result(Dynamic, String)

@external(erlang, "albedo_http_api", "encode")
pub fn encode_dynamic(value: Dynamic) -> String

@external(erlang, "albedo_http_api", "encode")
pub fn dynamic_json(value: Dynamic) -> json.Json

@external(erlang, "albedo_http_api", "timestamp")
pub fn timestamp(milliseconds: Int) -> String

@external(erlang, "albedo_http_api", "etag")
pub fn etag(encoded: String) -> String

@external(erlang, "albedo_http_api", "instance_id")
pub fn instance_id() -> String

@external(erlang, "albedo_http_api", "page_token")
pub fn page_token(secret: String, binding: String, state: String) -> String

@external(erlang, "albedo_http_api", "page_state")
pub fn page_state(
  secret: String,
  binding: String,
  token: String,
) -> Result(String, String)

@external(erlang, "albedo_http_api", "content_slice")
pub fn content_slice(
  text: String,
  offset: Int,
  limit: Int,
) -> Result(#(String, Int, Bool), String)

pub fn content_preview(text: String, limit: Int) -> String {
  content_slice(text, 0, limit)
  |> result.map(fn(slice) { slice.0 })
  |> result.unwrap("")
}

/// Retain each native item alongside the JSON used to measure its size.
pub fn bounded_items(
  items: List(item),
  budget: Int,
  overhead: Int,
  encode: fn(item) -> json.Json,
) -> List(#(item, json.Json)) {
  bounded_prefix(
    items,
    budget,
    fn(item) {
      let value = encode(item)
      Ok(#(value, string.byte_size(json.to_string(value)) + overhead))
    },
    [],
  )
  |> result.unwrap([])
}

/// Catalog entries have an individual limit as well as the page budget.
pub fn bounded_catalog(
  values: List(json.Json),
  budget: Int,
) -> Result(List(json.Json), Failure) {
  bounded_prefix(
    values,
    budget,
    fn(value) {
      let bytes = string.byte_size(json.to_string(value))
      case bytes > 65_536 {
        True ->
          Error(Failure(
            503,
            "catalog_item_unavailable",
            "catalog item exceeds its encoded size limit",
          ))
        False -> Ok(#(value, bytes + 1))
      }
    },
    [],
  )
  |> result.map(fn(items) { list.map(items, fn(item) { item.1 }) })
}

fn bounded_prefix(
  items: List(item),
  budget: Int,
  measure: fn(item) -> Result(#(json.Json, Int), Failure),
  kept: List(#(item, json.Json)),
) -> Result(List(#(item, json.Json)), Failure) {
  case items {
    [] -> Ok(list.reverse(kept))
    [item, ..rest] -> {
      use #(encoded, size) <- result.try(measure(item))
      case size > budget {
        True -> Ok(list.reverse(kept))
        False ->
          bounded_prefix(rest, budget - size, measure, [
            #(item, encoded),
            ..kept
          ])
      }
    }
  }
}

pub fn next_page(
  home: String,
  binding: String,
  has_more: Bool,
  last_state: Result(String, Nil),
) -> json.Json {
  case has_more, last_state {
    True, Ok(state) -> json.string(page_token(home, binding, state))
    _, _ -> json.null()
  }
}

@external(erlang, "albedo_http_api", "image_slice")
pub fn image_slice(
  base64: String,
  offset: Int,
  limit: Int,
) -> Result(#(String, Int, Bool), String)

@external(erlang, "albedo_http_api", "read_chunked")
pub fn read_chunked(
  connection: mist.Connection,
  limit: Int,
) -> Result(BitArray, mist.ReadError)

pub fn json_value(encoded: String) -> Result(json.Json, Failure) {
  use value <- result.try(
    strict_json(bit_array.from_string(encoded))
    |> result.map_error(invalid),
  )
  Ok(dynamic_json(value))
}

/// Decode a bus event once for forwarding and its structural type decision.
pub fn event_value(
  encoded: String,
) -> Result(#(json.Json, Option(String)), Failure) {
  use value <- result.try(
    strict_json(bit_array.from_string(encoded)) |> result.map_error(invalid),
  )
  let kind =
    decode.run(value, decode.field("type", decode.string, decode.success))
    |> option.from_result
  Ok(#(dynamic_json(value), kind))
}

pub fn fields(encoded: String) -> Result(List(#(String, json.Json)), Failure) {
  use value <- result.try(
    strict_json(bit_array.from_string(encoded)) |> result.map_error(invalid),
  )
  decode.run(value, decode.dict(decode.string, decode.dynamic))
  |> result.map_error(fn(_) { invalid("expected a JSON object") })
  |> result.map(fn(fields) {
    dict.to_list(fields)
    |> list.map(fn(field) { #(field.0, dynamic_json(field.1)) })
  })
}

pub fn object_fields(
  value: Dynamic,
  allowed: List(String),
) -> Result(Nil, Failure) {
  use fields <- result.try(
    decode.run(value, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error(invalid("request must be a JSON object")),
  )
  case dict.keys(fields) |> list.all(list.contains(allowed, _)) {
    True -> Ok(Nil)
    False -> Error(invalid("request contains an unknown field"))
  }
}

pub fn object(
  allowed: List(String),
  decoder: decode.Decoder(a),
) -> decode.Decoder(a) {
  use raw <- decode.then(decode.dynamic)
  case object_fields(raw, allowed) {
    Ok(_) -> decoder
    Error(_) ->
      decode.then(decoder, fn(value) {
        decode.failure(value, "object without unknown fields")
      })
  }
}

pub fn bounded_string(maximum: Int, nonempty: Bool) -> decode.Decoder(String) {
  use value <- decode.then(decode.string)
  case
    scalar_prefix(value, maximum) == value
    && { !nonempty || string.trim(value) != "" }
  {
    True -> decode.success(value)
    False -> decode.failure(value, "bounded string")
  }
}

pub fn body(
  req: request.Request(BitArray),
  allowed: List(String),
  decoder: decode.Decoder(value),
) -> Result(value, Failure) {
  let expected = case req.method {
    Patch -> "application/merge-patch+json"
    _ -> "application/json"
  }
  use _ <- result.try(case request.get_header(req, "content-type") {
    Ok(content_type) ->
      case
        string.split(content_type, ";")
        |> list.first
        |> result.map(fn(value) { string.lowercase(string.trim(value)) })
      {
        Ok(media_type) if media_type == expected -> Ok(Nil)
        _ ->
          Error(Failure(
            415,
            "unsupported_media_type",
            "unsupported request media type",
          ))
      }
    Error(_) ->
      Error(Failure(
        415,
        "unsupported_media_type",
        "a JSON content type is required",
      ))
  })
  use value <- result.try(strict_json(req.body) |> result.map_error(invalid))
  use _ <- result.try(object_fields(value, allowed))
  decode.run(value, decoder)
  |> result.replace_error(invalid("request fields have invalid values"))
}

pub fn empty_body(req: request.Request(BitArray)) -> Result(Nil, Failure) {
  case bit_array.byte_size(req.body) {
    0 -> Ok(Nil)
    _ -> body(req, [], decode.success(Nil))
  }
}

pub fn parameters(
  req: request.Request(a),
  allowed: List(String),
) -> Result(List(#(String, String)), Failure) {
  use fields <- result.try(
    uri.parse_query(option.unwrap(req.query, ""))
    |> result.replace_error(invalid("query is malformed")),
  )
  let keys = list.map(fields, fn(field) { field.0 })
  case
    list.all(keys, list.contains(allowed, _))
    && list.length(keys) == dict.size(dict.from_list(fields))
  {
    True -> Ok(fields)
    False -> Error(invalid("query contains an unknown or repeated parameter"))
  }
}

pub fn integer_parameter(
  fields: List(#(String, String)),
  key: String,
  default: Int,
  maximum: Int,
) -> Result(Int, Failure) {
  case list.key_find(fields, key) {
    Error(_) -> Ok(default)
    Ok(value) ->
      case int.parse(value) {
        Ok(number) if number >= 0 && number <= maximum -> Ok(number)
        _ -> Error(invalid("query integer is outside its allowed range"))
      }
  }
}

pub fn require_match(
  req: request.Request(a),
  current: String,
) -> Result(Nil, Failure) {
  case request.get_header(req, "if-match") {
    Error(_) ->
      Error(Failure(428, "precondition_required", "If-Match is required"))
    Ok(observed) if observed == current -> Ok(Nil)
    Ok(_) ->
      Error(Failure(
        412,
        "precondition_failed",
        "the observed resource has changed",
      ))
  }
}

pub fn require_creation(req: request.Request(a)) -> Result(Nil, Failure) {
  case request.get_header(req, "if-none-match") {
    Ok("*") -> Ok(Nil)
    Error(_) ->
      Error(Failure(
        428,
        "precondition_required",
        "If-None-Match: * is required",
      ))
    Ok(_) -> Error(invalid("creation requires If-None-Match: *"))
  }
}

@external(erlang, "albedo_http_api", "accept")
fn negotiate_accept(header: String, live: Bool) -> Result(Bool, String)

pub fn accepts_json(req: request.Request(a)) -> Result(Nil, Failure) {
  negotiate(req, False) |> result.replace(Nil)
}

pub fn wants_events(req: request.Request(a)) -> Result(Bool, Failure) {
  negotiate(req, True)
}

fn negotiate(req: request.Request(a), live: Bool) -> Result(Bool, Failure) {
  case request.get_header(req, "accept") {
    Error(_) -> Ok(False)
    Ok(header) ->
      negotiate_accept(header, live)
      |> result.map_error(fn(detail) { Failure(406, "not_acceptable", detail) })
  }
}

fn nullable_string(
  key: String,
  next: fn(Option(String)) -> decode.Decoder(a),
) -> decode.Decoder(a) {
  let #(maximum, nonempty) = case key {
    "name" -> #(4096, False)
    "effort" -> #(100, False)
    "client_id" -> #(512, False)
    _ -> #(512, True)
  }
  let value = case key {
    "client_id" -> decode.map(bounded_string(maximum, nonempty), option.Some)
    _ -> decode.optional(bounded_string(maximum, nonempty))
  }
  decode.optional_field(key, None, value, next)
}

pub fn creation(req: request.Request(BitArray)) -> Result(Creation, Failure) {
  use kind <- result.try(body(
    req,
    [
      "kind", "workspace", "name", "provider_profile", "model", "effort",
      "source_session_id", "checkpoint_id", "parent_id", "address",
      "initial_input_id", "task",
    ],
    decode.field("kind", decode.string, decode.success),
  ))
  case kind {
    "new" ->
      body(
        req,
        ["kind", "workspace", "name", "provider_profile", "model", "effort"],
        {
          use workspace <- decode.field("workspace", bounded_string(4096, True))
          use name <- nullable_string("name")
          use provider <- nullable_string("provider_profile")
          use model <- nullable_string("model")
          use effort <- nullable_string("effort")
          decode.success(NewSession(workspace, name, provider, model, effort))
        },
      )
    "fork" ->
      body(req, ["kind", "source_session_id", "checkpoint_id", "name"], {
        use source <- decode.field(
          "source_session_id",
          bounded_string(512, True),
        )
        use checkpoint <- decode.field(
          "checkpoint_id",
          bounded_string(512, True),
        )
        use name <- nullable_string("name")
        decode.success(ForkSession(source, checkpoint, name))
      })
    "child" ->
      body(
        req,
        [
          "kind",
          "parent_id",
          "address",
          "name",
          "initial_input_id",
          "task",
          "model",
          "effort",
        ],
        {
          use parent <- decode.field("parent_id", bounded_string(512, True))
          use address <- decode.field("address", bounded_string(512, True))
          use name <- decode.field("name", bounded_string(4096, False))
          use input_id <- decode.field(
            "initial_input_id",
            bounded_string(512, True),
          )
          use task <- decode.field("task", decode.string)
          use model <- nullable_string("model")
          use effort <- nullable_string("effort")
          decode.success(ChildSession(
            parent,
            address,
            name,
            input_id,
            task,
            model,
            effort,
          ))
        },
      )
    _ -> Error(invalid("unknown session creation kind"))
  }
}

pub fn creation_intent(creation: Creation) -> json.Json {
  json.object(case creation {
    NewSession(workspace, name, provider, model, effort) -> [
      #("kind", json.string("new")),
      #("workspace", json.string(workspace)),
      #("name", json.nullable(name, json.string)),
      #("provider_profile", json.nullable(provider, json.string)),
      #("model", json.nullable(model, json.string)),
      #("effort", json.nullable(effort, json.string)),
    ]
    ForkSession(source, checkpoint, name) -> [
      #("kind", json.string("fork")),
      #("source_session_id", json.string(source)),
      #("checkpoint_id", json.string(checkpoint)),
      #("name", json.nullable(name, json.string)),
    ]
    ChildSession(parent, address, name, input_id, task, model, effort) -> [
      #("kind", json.string("child")),
      #("parent_id", json.string(parent)),
      #("address", json.string(address)),
      #("name", json.string(name)),
      #("initial_input_id", json.string(input_id)),
      #("task", json.string(task)),
      #("model", json.nullable(model, json.string)),
      #("effort", json.nullable(effort, json.string)),
    ]
  })
}

pub fn input(req: request.Request(BitArray)) -> Result(Input, Failure) {
  use kind <- result.try(body(
    req,
    [
      "kind", "text", "image", "client_id", "candidate_id", "catalog_revision",
      "arguments", "command_id",
    ],
    decode.field("kind", decode.string, decode.success),
  ))
  case kind {
    "message" ->
      body(req, ["kind", "text", "image", "client_id"], {
        use text <- decode.field("text", decode.string)
        use image <- decode.optional_field(
          "image",
          None,
          decode.map(
            object(["mime_type", "data"], {
              use mime_type <- decode.field(
                "mime_type",
                bounded_string(256, True),
              )
              use data <- decode.field("data", decode.string)
              decode.success(ImageUpload(mime_type, data))
            }),
            option.Some,
          ),
        )
        use client_id <- nullable_string("client_id")
        decode.success(MessageInput(text, image, client_id))
      })
    "continue" ->
      body(req, ["kind", "client_id"], {
        use client_id <- nullable_string("client_id")
        decode.success(ContinueInput(client_id))
      })
    "skill" ->
      body(
        req,
        ["kind", "candidate_id", "catalog_revision", "arguments", "client_id"],
        {
          use candidate <- decode.field(
            "candidate_id",
            bounded_string(512, True),
          )
          use revision <- decode.field(
            "catalog_revision",
            bounded_string(512, True),
          )
          use arguments <- decode.field("arguments", decode.string)
          use client_id <- nullable_string("client_id")
          decode.success(SkillInput(candidate, revision, arguments, client_id))
        },
      )
    "command" ->
      body(req, ["kind", "command_id", "arguments", "client_id"], {
        use command_id <- decode.field("command_id", bounded_string(512, True))
        use arguments <- decode.field("arguments", decode.dynamic)
        use client_id <- nullable_string("client_id")
        decode.success(CommandInput(command_id, arguments, client_id))
      })
    _ -> Error(invalid("unknown input kind"))
  }
}

pub fn interrupt(req: request.Request(BitArray)) -> Result(Interrupt, Failure) {
  body(req, ["run_id", "through_input_order"], {
    use run_id <- decode.field(
      "run_id",
      decode.optional(bounded_string(512, True)),
    )
    use through <- decode.field("through_input_order", decode.int)
    decode.success(Interrupt(run_id, through))
  })
  |> result.try(fn(interrupt) {
    case
      interrupt.through_input_order >= 0
      && interrupt.through_input_order <= 9_007_199_254_740_991
    {
      True -> Ok(interrupt)
      False -> Error(invalid("input order is outside its allowed range"))
    }
  })
}

pub fn input_intent(input: Input) -> json.Json {
  json.object(case input {
    MessageInput(text, image, _) -> [
      #("kind", json.string("message")),
      #("text", json.string(text)),
      #(
        "image",
        json.nullable(image, fn(image) {
          json.object([
            #("mime_type", json.string(image.mime_type)),
            #("data", json.string(image.data)),
          ])
        }),
      ),
    ]
    ContinueInput(_) -> [
      #("kind", json.string("continue")),
    ]
    SkillInput(candidate, revision, arguments, _) -> [
      #("kind", json.string("skill")),
      #("candidate_id", json.string(candidate)),
      #("catalog_revision", json.string(revision)),
      #("arguments", json.string(arguments)),
    ]
    CommandInput(command, arguments, _) -> [
      #("kind", json.string("command")),
      #("command_id", json.string(command)),
      #("arguments", dynamic_json(arguments)),
    ]
  })
}

@external(erlang, "albedo_http_api", "scalar_prefix")
pub fn scalar_prefix(text: String, limit: Int) -> String

pub fn failure(code: String) -> Failure {
  case code {
    "operation_conflict" ->
      Failure(409, "id_conflict", "resource identity belongs to another intent")
    "input_conflict" ->
      Failure(409, code, "input identity belongs to another intent")
    "image_invalid" -> Failure(400, code, "image payload is invalid")
    "message is empty" -> Failure(400, "message_empty", code)
    "operation_expired" ->
      Failure(
        410,
        "identity_expired",
        "resource identity is outside its admission window",
      )
    "operation_invalid" ->
      Failure(
        400,
        "identity_invalid",
        "resource identity must be a current UUIDv7",
      )
    "operation_future" ->
      Failure(
        400,
        "identity_future",
        "resource identity is beyond the allowed future clock window",
      )
    "session not found" ->
      Failure(404, "session_not_found", "session was not found")
    "session_exists" ->
      Failure(412, "session_exists", "session resource already exists")
    "session_deleted" ->
      Failure(410, "session_deleted", "session resource was deleted")
    "configuration_changed" | "family_changed" ->
      Failure(412, code, "observed configuration or family changed")
    "daemon is shutting down" ->
      Failure(503, "daemon_unavailable", "daemon is unavailable")
    "session_has_children" ->
      Failure(409, code, "leaf deletion requires a session without children")
    "context_changed" ->
      Failure(410, code, "prepared context changed; read a new snapshot")
    "name must be 1-32 characters of a-z, 0-9, '-' or '_'"
    | "'parent' is reserved"
    | "'self' is reserved"
    | "'all' is reserved" -> Failure(400, "child_address_invalid", code)
    "expected a model"
    | "unsupported effort"
    | "saved profile effort is unsupported by this model" ->
      Failure(400, "model_selection_invalid", code)
    "provider is not configured; run /login"
    | "provider configuration is invalid; run /login"
    | "active provider is not configured; run /login"
    | "session provider is not configured; run /login" ->
      Failure(409, "provider_unconfigured", code)
    "provider_profile_unknown" ->
      Failure(400, code, "provider profile was not found")
    "model is available from multiple providers; use provider/model" ->
      Failure(409, "model_ambiguous", code)
    "checkpoint not found" -> Failure(404, "checkpoint_not_found", code)
    "invalid branch checkpoint or session id" ->
      Failure(400, "checkpoint_invalid", code)
    "duplicate tool call id before checkpoint"
    | "checkpoint contains a tool result without its call" ->
      Failure(409, "checkpoint_invalid", code)
    "catalog_changed" ->
      Failure(409, code, "discovery changed; refresh the catalog")
    "settings_changed" ->
      Failure(412, code, "provider settings changed during the edit")
    "session_busy"
    | "session must be idle to upgrade the kernel"
    | "session must be idle to change workspace"
    | "session must be idle to compact"
    | "session must be idle to delete"
    | "kernel preparation is already in progress" ->
      Failure(409, "session_busy", code)
    "candidate_unavailable" ->
      Failure(409, code, "selected capability is unavailable")
    "duplicate candidate preference" -> Failure(400, "candidate_conflict", code)
    "selection_conflict" ->
      Failure(400, code, "choose one compaction strategy in a selection patch")
    "selection_invalid" ->
      Failure(
        400,
        code,
        "selected extensions have incompatible capabilities or unmet dependencies",
      )
    "unsupported reasoning effort" -> Failure(400, "effort_invalid", code)
    "no compaction strategy is enabled"
    | "no conversation history to compact" ->
      Failure(409, "compaction_unavailable", code)
    "deletion_in_progress" ->
      Failure(409, code, "session deletion is in progress")
    _ ->
      case string.starts_with(code, "model is not available from provider ") {
        True -> Failure(409, "model_unavailable", code)
        False ->
          case
            string.starts_with(code, "a child named '")
            && string.ends_with(code, "' already exists")
          {
            True ->
              Failure(409, "child_address_conflict", scalar_prefix(code, 4096))
            False ->
              Failure(503, "request_unavailable", scalar_prefix(code, 4096))
          }
      }
  }
}

pub fn answer(
  outcome: Result(response.Response(mist.ResponseData), Failure),
) -> response.Response(mist.ResponseData) {
  case outcome {
    Ok(response) -> response
    Error(failure) -> fail(failure)
  }
}

pub fn json_parameters(
  req: request.Request(a),
  allowed: List(String),
) -> Result(List(#(String, String)), Failure) {
  use _ <- result.try(accepts_json(req))
  parameters(req, allowed)
}

pub fn limit_parameter(
  parameters: List(#(String, String)),
  default: Int,
) -> Result(Int, Failure) {
  use limit <- result.try(integer_parameter(parameters, "limit", default, 200))
  case limit > 0 {
    True -> Ok(limit)
    False -> Error(invalid("limit must be between 1 and 200"))
  }
}

pub fn workspace_failure(failure: location.Failure) -> Failure {
  case failure {
    location.Invalid(detail) -> Failure(400, "workspace_invalid", detail)
    location.Unavailable(detail) ->
      Failure(503, "workspace_unavailable", detail)
  }
}

pub fn page_binding(
  req: request.Request(a),
  parameters: List(#(String, String)),
) -> String {
  req.path
  <> "?"
  <> uri.query_to_string(
    list.filter(parameters, fn(pair) { pair.0 != "next" })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) }),
  )
}

pub fn page_offset(
  secret: String,
  req: request.Request(a),
  parameters: List(#(String, String)),
  binding: String,
  initial: Int,
) -> Result(Int, Failure) {
  case list.key_find(parameters, "next") {
    Error(_) -> Ok(initial)
    Ok(token) -> {
      use state <- result.try(
        page_state(secret, page_binding(req, parameters) <> binding, token)
        |> result.map_error(fn(code) {
          case code {
            "continuation_expired" -> Failure(410, code, "continuation expired")
            _ ->
              invalid("continuation does not belong to this resource and query")
          }
        }),
      )
      int.parse(state)
      |> result.map_error(fn(_) { invalid("invalid continuation") })
    }
  }
}

pub fn continuation(
  secret: String,
  req: request.Request(a),
  parameters: List(#(String, String)),
  binding: String,
  state: Int,
) -> json.Json {
  json.string(page_token(
    secret,
    page_binding(req, parameters) <> binding,
    int.to_string(state),
  ))
}

pub fn boolean_parameter(
  parameters: List(#(String, String)),
  name: String,
) -> Result(Option(Bool), Failure) {
  case list.key_find(parameters, name) {
    Error(_) -> Ok(None)
    Ok("true") -> Ok(Some(True))
    Ok("false") -> Ok(Some(False))
    Ok(_) -> Error(invalid(name <> " must be true or false"))
  }
}

/// Translate native admission failures without changing their HTTP meaning.
pub fn native_failure(value: #(Int, String, String)) -> Failure {
  Failure(value.0, value.1, value.2)
}
