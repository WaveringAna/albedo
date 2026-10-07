//// Read-only projections at the native settings document boundary.
//// Values not validated by the original reader remain raw until encoding.

import albedo/daemon/configuration
import albedo/harness/cache_ttl
import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri

pub type Error {
  InvalidSection
  InvalidValue
}

type Profile {
  Profile(
    saved: configuration.SavedProfile,
    effort: Dynamic,
    image_edge: Dynamic,
    account_id: Dynamic,
    project: Dynamic,
    location: Dynamic,
    has_key: Bool,
  )
}

type UI {
  UI(thinking: Bool, tools: Bool, dismissed_notices: List(String))
}

type Source {
  Literal(String)
  Environment(Dynamic)
}

@external(erlang, "albedo_settings_read", "json_null")
fn null() -> Dynamic

fn object(fields: List(#(String, Dynamic))) -> Dynamic {
  dynamic.properties(
    list.map(fields, fn(field) { #(dynamic.string(field.0), field.1) }),
  )
}

fn fields(value: Dynamic) -> Result(Dict(String, Dynamic), Error) {
  decode.run(value, decode.dict(decode.string, decode.dynamic))
  |> result.replace_error(InvalidSection)
}

fn section(
  value: Dynamic,
  name: String,
) -> Result(Dict(String, Dynamic), Error) {
  use parent <- result.try(fields(value))
  section_fields(parent, name)
}

fn section_fields(
  parent: Dict(String, Dynamic),
  name: String,
) -> Result(Dict(String, Dynamic), Error) {
  case dict.get(parent, name) {
    Ok(saved) -> fields(saved)
    Error(_) -> Ok(dict.new())
  }
}

fn value(
  fields: Dict(String, Dynamic),
  name: String,
  default: Dynamic,
) -> Dynamic {
  dict.get(fields, name) |> result.unwrap(default)
}

fn nonempty(value: Dynamic) -> Dynamic {
  case decode.run(value, decode.string) {
    Ok("") -> null()
    _ -> value
  }
}

pub fn ui_group(picker: Dynamic) -> Result(Dynamic, Error) {
  let text = {
    use text <- decode.then(decode.string)
    case string.byte_size(text) >= 1 && string.byte_size(text) <= 512 {
      True -> decode.success(text)
      False -> decode.failure("", "notice identifier")
    }
  }
  let decoder = {
    use thinking <- decode.optional_field("thinking", False, decode.bool)
    use tools <- decode.optional_field("tools", False, decode.bool)
    use notices <- decode.optional_field(
      "dismissed_notices",
      [],
      decode.list(text),
    )
    decode.success(UI(thinking, tools, notices))
  }
  use ui <- result.try(
    decode.run(picker, decoder) |> result.replace_error(InvalidValue),
  )
  case list.length(ui.dismissed_notices) <= 1000 {
    False -> Error(InvalidValue)
    True ->
      Ok(
        object([
          #("thinking", dynamic.bool(ui.thinking)),
          #("tools", dynamic.bool(ui.tools)),
          #(
            "dismissed_notices",
            dynamic.list(list.map(ui.dismissed_notices, dynamic.string)),
          ),
        ]),
      )
  }
}

pub fn groups(documents: Dict(String, Dynamic)) -> Result(Dynamic, Error) {
  let assert Ok(config) = dict.get(documents, "config.json")
  let assert Ok(creds) = dict.get(documents, "creds.json")
  let assert Ok(extensions) = dict.get(documents, "extensions.json")
  let assert Ok(picker) = dict.get(documents, "picker.json")
  use named <- result.try(
    configuration.named_config(config) |> result.replace_error(InvalidSection),
  )
  let assert Ok(saved_profiles) = dict.get(named, "providers")
  use saved_profiles <- result.try(fields(saved_profiles))
  use profiles <- result.try(
    list.try_map(dict.to_list(saved_profiles), fn(entry) {
      use profile <- result.try(profile(entry.0, entry.1, creds))
      Ok(#(entry.0, profile))
    }),
  )
  use composition <- result.try(composition_groups(documents))
  use raised <- result.try(section(extensions, "raisedCaps"))
  use ui <- result.try(ui_group(picker))
  let providers =
    object([
      #("default_profile", nonempty(value(named, "active", null()))),
      #(
        "profiles",
        object(
          list.map(profiles, fn(entry) { #(entry.0, profile_value(entry.1)) }),
        ),
      ),
    ])
  let priors =
    profiles
    |> list.sort(fn(first, second) { string.compare(first.0, second.0) })
    |> list.take(200)
    |> list.map(fn(entry) { cache_prior(entry.0, entry.1.saved) })
  Ok(
    object(
      list.append(dict.to_list(composition), [
        #("providers", providers),
        #(
          "models",
          object([
            #("raised_caps", object(dict.to_list(raised))),
            #("cache_ttl_priors", dynamic.list(priors)),
          ]),
        ),
        #("ui", ui),
      ]),
    ),
  )
}

fn profile(
  name: String,
  raw: Dynamic,
  creds: Dynamic,
) -> Result(Profile, Error) {
  use saved <- result.try(
    configuration.validate_profile(name, raw)
    |> result.replace_error(InvalidValue),
  )
  use fields <- result.try(fields(raw))
  let has_inline_key = case
    decode.run(value(fields, "apiKey", null()), decode.string)
  {
    Ok(key) -> key != ""
    _ -> False
  }
  use has_key <- result.try(case has_inline_key {
    True -> Ok(True)
    False -> {
      use keys <- result.try(section(creds, "providers"))
      let stored_key = dict.get(keys, name) |> result.unwrap(object([]))
      // Non-map credential entries previously counted as missing keys.
      Ok(
        case
          decode.run(stored_key, {
            use key <- decode.field("apiKey", decode.string)
            decode.success(key)
          })
        {
          Ok(key) -> key != ""
          Error(_) -> False
        },
      )
    }
  })
  Ok(Profile(
    saved,
    value(fields, "effort", null()),
    value(fields, "imageEdge", null()),
    value(fields, "accountId", null()),
    value(fields, "project", null()),
    value(fields, "location", null()),
    has_key,
  ))
}

fn profile_value(profile: Profile) -> Dynamic {
  object([
    #("extension", dynamic.string(profile.saved.extension)),
    #("endpoint", nonempty(dynamic.string(profile.saved.endpoint))),
    #("protocol", dynamic.string(types.protocol_name(profile.saved.protocol))),
    #("model", dynamic.string(profile.saved.model)),
    #("effort", profile.effort),
    #("image_edge", profile.image_edge),
    #("account_id", profile.account_id),
    #("project", profile.project),
    #("location", profile.location),
    #("has_key", dynamic.bool(profile.has_key)),
  ])
}

pub fn composition_groups(
  documents: Dict(String, Dynamic),
) -> Result(Dict(String, Dynamic), Error) {
  let assert Ok(extensions) = dict.get(documents, "extensions.json")
  let assert Ok(capabilities) = dict.get(documents, "capabilities.json")
  let assert Ok(creds) = dict.get(documents, "creds.json")
  use mcp <- result.try(section(extensions, "mcp"))
  use definitions <- result.try(section_fields(mcp, "servers"))
  use views <- result.try(
    list.try_map(dict.to_list(definitions), fn(entry) {
      use secrets <- result.try(section(creds, "mcp"))
      let secret = dict.get(secrets, entry.0) |> result.unwrap(object([]))
      use view <- result.try(mcp_view(entry.1, secret))
      Ok(#(entry.0, view))
    }),
  )
  use defaults <- result.try(section(extensions, "enabled"))
  use global <- result.try(section(capabilities, "global"))
  use preferences <- result.try(
    list.try_fold(dict.to_list(global), [], fn(preferences, kind) {
      use choices <- result.try(
        fields(kind.1) |> result.replace_error(InvalidValue),
      )
      Ok(list.append(
        preferences,
        list.map(dict.to_list(choices), fn(choice) {
          #(kind.0 <> ":" <> choice.0, choice.1)
        }),
      ))
    }),
  )
  Ok(
    dict.from_list([
      #("mcp", object([#("definitions", object(views))])),
      #("extensions", object([#("defaults", object(dict.to_list(defaults)))])),
      #("capabilities", object([#("preferences", object(preferences))])),
    ]),
  )
}

fn mcp_view(raw: Dynamic, secret: Dynamic) -> Result(Dynamic, Error) {
  use definition <- result.try(
    fields(raw) |> result.replace_error(InvalidValue),
  )
  use transport <- result.try(
    dict.get(definition, "type") |> result.replace_error(InvalidValue),
  )
  let defaults =
    dict.from_list([
      #("enabled", dynamic.bool(True)),
      #("transport", transport),
      #("command", null()),
      #("arguments", dynamic.list([])),
      #("cwd", null()),
      #("url", null()),
      #("bearer_token_env_var", null()),
      #("enabled_tools", null()),
      #("disabled_tools", dynamic.list([])),
      #("startup_timeout_ms", dynamic.int(20_000)),
      #("call_timeout_ms", dynamic.int(60_000)),
    ])
  let public =
    list.fold(mcp_fields(), defaults, fn(public, name) {
      case dict.get(definition, name.1) {
        Ok(saved) -> dict.insert(public, name.0, saved)
        Error(_) -> public
      }
    })
  use environment <- result.try(source_view(definition, "env"))
  use headers <- result.try(source_view(definition, "headers"))
  use secret_fields <- result.try(
    fields(secret) |> result.replace_error(InvalidValue),
  )
  use secret_environment <- result.try(section_fields(secret_fields, "env"))
  use secret_headers <- result.try(section_fields(secret_fields, "headers"))
  Ok(
    object(
      list.append(dict.to_list(public), [
        #("environment", environment),
        #("headers", headers),
        #(
          "secret_presence",
          object([
            #(
              "bearer_token",
              dynamic.bool(dict.has_key(secret_fields, "bearerToken")),
            ),
            #("environment", sorted_names(secret_environment)),
            #("headers", sorted_names(secret_headers)),
          ]),
        ),
      ]),
    ),
  )
}

fn source_view(
  definition: Dict(String, Dynamic),
  key: String,
) -> Result(Dynamic, Error) {
  use sources <- result.try(section_fields(definition, key))
  let decoder =
    decode.one_of(decode.string |> decode.map(Literal), [
      {
        use name <- decode.field("env", decode.dynamic)
        decode.success(Environment(name))
      },
    ])
  use sources <- result.try(
    list.try_map(dict.to_list(sources), fn(entry) {
      use source <- result.try(
        decode.run(entry.1, decoder) |> result.replace_error(InvalidValue),
      )
      let #(kind, text) = case source {
        Literal(text) -> #("literal", dynamic.string(text))
        Environment(name) -> #("env", name)
      }
      Ok(#(
        entry.0,
        object([#("source", dynamic.string(kind)), #("value", text)]),
      ))
    }),
  )
  Ok(object(sources))
}

fn sorted_names(fields: Dict(String, Dynamic)) -> Dynamic {
  fields
  |> dict.keys
  |> list.sort(string.compare)
  |> list.map(dynamic.string)
  |> dynamic.list
}

fn cache_prior(name: String, profile: configuration.SavedProfile) -> Dynamic {
  let host =
    uri.parse(profile.endpoint)
    |> result.map(fn(uri) { uri.host })
    |> result.unwrap(None)
    |> option.unwrap("")
  let entry = cache_ttl.lookup(profile.extension, host, profile.model)
  let seconds =
    option.then(entry, cache_ttl.clock_tier)
    |> option.map(fn(tier) { tier.seconds })
  object([
    #("provider", dynamic.string(name)),
    #("model", dynamic.string(profile.model)),
    #("ttl_seconds", case seconds {
      Some(seconds) -> dynamic.int(seconds)
      None -> null()
    }),
    #(
      "source",
      dynamic.string(case entry {
        Some(entry) -> entry.source
        None -> "unknown"
      }),
    ),
  ])
}

pub fn mcp_fields() -> List(#(String, String)) {
  [
    #("enabled", "enabled"),
    #("transport", "type"),
    #("command", "command"),
    #("arguments", "args"),
    #("cwd", "cwd"),
    #("url", "url"),
    #("bearer_token_env_var", "bearerTokenEnvVar"),
    #("enabled_tools", "enabledTools"),
    #("disabled_tools", "disabledTools"),
    #("startup_timeout_ms", "startupTimeoutMs"),
    #("call_timeout_ms", "callTimeoutMs"),
  ]
}
