//// Provider settings, account resources, and sign-in operations.

import albedo/daemon/bus
import albedo/daemon/http_api
import albedo/daemon/registry.{type Config, type Message, Logins}
import albedo/daemon/session_catalog
import albedo/daemon/settings
import albedo/harness/extension
import albedo/harness/oauth
import albedo/harness/runtime
import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http.{Get, Patch, Put}
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import mist

pub fn settings(
  config: Config,
  registry: Subject(Message),
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(http_api.json_parameters(req, ["group"]))
    let group = list.key_find(parameters, "group") |> result.unwrap("")
    use _ <- result.try(case group {
      "" if req.method == Get -> Ok(Nil)
      _ ->
        settings.parse_group(group)
        |> result.replace(Nil)
        |> result.map_error(http_api.invalid)
    })
    case req.method {
      Get -> {
        use observed <- result.try(
          settings.observe_group(config.home, group)
          |> result.map_error(http_api.native_failure),
        )
        let response = http_api.raw(200, observed.value)
        Ok(case observed.etag {
          None -> response
          Some(etag) -> response |> response.set_header("etag", etag)
        })
      }
      _ -> {
        let allowed = case group {
          "providers" -> ["default_profile", "profiles"]
          "mcp" -> ["definitions", "validate_connection"]
          "extensions" -> ["defaults"]
          "capabilities" -> [
            "catalog_session_id",
            "catalog_revision",
            "choices",
          ]
          "models" -> ["raised_caps"]
          _ -> ["thinking", "tools", "dismissed_notices"]
        }
        use patch <- result.try(http_api.body(req, allowed, decode.dynamic))
        use host <- result.try(
          registry.host(registry) |> result.map_error(http_api.failure),
        )
        let logins = actor.call(registry, 5000, Logins)
        let providers =
          runtime.installed(host)
          |> list.filter(fn(item) {
            list.any(item.plugins, fn(plugin) {
              case plugin {
                extension.ModelProviderPlugin(_) -> True
                _ -> False
              }
            })
          })
          |> list.map(fn(item) { item.name })
        let composes =
          settings.parse_group(group)
          |> result.map(settings.composes)
          |> result.unwrap(False)
        use before <- result.try(case composes {
          True ->
            settings.composition_revision(config.home)
            |> result.map(Some)
            |> result.map_error(http_api.failure)
          False -> Ok(None)
        })
        use changed <- result.try(
          settings.patch_group(
            config.home,
            group,
            request.get_header(req, "if-match") |> result.unwrap(""),
            http_api.encode_dynamic(patch),
            providers,
            logins,
            fn(patch) { resolve_global_capabilities(config.home, host, patch) },
            fn(current, changes) {
              extension.change_defaults(
                runtime.installed(host),
                runtime.base_defaults(host),
                current,
                changes,
              )
              |> result.map_error(fn(error) {
                case error {
                  extension.ConflictingStrategies -> #(
                    400,
                    "selection_conflict",
                    "choose one compaction strategy in each patch",
                  )
                  extension.InvalidSelection(detail) -> #(
                    400,
                    "selection_invalid",
                    detail,
                  )
                }
              })
            },
          )
          |> result.map_error(http_api.native_failure),
        )
        use fields <- result.try(http_api.fields(changed))
        use revision <- result.try(
          settings.composition_revision(config.home)
          |> result.map_error(http_api.failure),
        )
        use enabled <- result.try(
          runtime.global(host) |> result.map_error(http_api.failure),
        )
        let service_names =
          list.filter_map(enabled, fn(item) {
            case extension.service(enabled, item.name) {
              Ok(_) -> Ok(item.name)
              Error(_) -> Error(Nil)
            }
          })
        let service_revision =
          http_api.etag(
            json.array(service_names, json.string) |> json.to_string,
          )
        let application =
          json.object([
            #("desired_revision", json.string(revision)),
            #("active_service_revision", json.string(service_revision)),
            // Which sessions are behind is asked separately, through
            // GET /sessions?needs_reload=true: it observes every loaded one.
            #(
              "composition_changed",
              json.bool(composes && before != Some(revision)),
            ),
            #(
              "validation",
              list.key_find(fields, "validation")
                |> result.unwrap(json.string("not_applicable")),
            ),
            #("warnings", json.array([], fn(value) { value })),
          ])
        let fields = list.filter(fields, fn(field) { field.0 != "validation" })
        bus.invalidate(["/settings", "/sessions"], [], True)
        Ok(http_api.reply(
          200,
          json.object([#("application", application), ..fields]),
        ))
      }
    }
  }
  http_api.answer(outcome)
}

pub fn auth(
  config: Config,
  registry: Subject(Message),
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use _ <- result.try(http_api.json_parameters(req, []))
    let logins = actor.call(registry, 5000, Logins)
    use value <- result.try(
      oauth.auth_snapshot(config.home, logins)
      |> result.map_error(http_api.native_failure),
    )
    Ok(http_api.raw(200, value))
  }
  http_api.answer(outcome)
}

pub fn login(
  config: Config,
  registry: Subject(Message),
  id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use _ <- result.try(http_api.json_parameters(req, []))
    let logins = actor.call(registry, 5000, Logins)
    case req.method {
      Put -> {
        use submitted <- result.try(
          http_api.body(req, ["provider", "flow", "values"], {
            use provider <- decode.field("provider", decode.string)
            use flow <- decode.optional_field("flow", "browser", decode.string)
            use values <- decode.field(
              "values",
              decode.dict(decode.string, decode.dynamic),
            )
            decode.success(#(provider, flow, values))
          }),
        )
        let #(provider, flow, values) = submitted
        use _ <- result.try(
          case
            list.contains(["browser", "manual"], flow) && dict.size(values) == 0
          {
            True -> Ok(Nil)
            False ->
              Error(http_api.invalid(
                "provider supports browser and manual flows with no form values",
              ))
          },
        )
        let intent =
          json.object([
            #("provider", json.string(provider)),
            #("flow", json.string(flow)),
            #("values", json.object([])),
          ])
          |> json.to_string
        let login =
          list.find(logins, fn(login) { login.provider == provider })
          |> result.map(Some)
          |> result.unwrap(None)
        use created <- result.try(
          oauth.start_identified(config.home, id, provider, login, intent)
          |> result.map_error(http_api.native_failure),
        )
        let response =
          http_api.raw(
            case created.0 {
              True -> 201
              False -> 200
            },
            created.1,
          )
          |> response.set_header("etag", http_api.etag(created.1))
        Ok(case created.0 {
          True ->
            response |> response.set_header("location", "/auth/logins/" <> id)
          False -> response
        })
      }
      Get -> {
        use value <- result.try(
          oauth.get_identified(config.home, id, logins)
          |> result.map_error(http_api.native_failure),
        )
        Ok(
          http_api.raw(200, value)
          |> response.set_header("etag", http_api.etag(value)),
        )
      }
      Patch -> {
        use supplied <- result.try(http_api.body(
          req,
          ["response"],
          decode.field("response", decode.string, decode.success),
        ))
        use _ <- result.try(
          case
            string.length(supplied) > 0
            && bit_array.byte_size(bit_array.from_string(supplied)) <= 16_384
          {
            True -> Ok(Nil)
            False ->
              Error(http_api.invalid(
                "response must contain at most 16384 bytes",
              ))
          },
        )
        use value <- result.try(
          oauth.input_identified(
            config.home,
            id,
            request.get_header(req, "if-match") |> result.unwrap(""),
            supplied,
            logins,
          )
          |> result.map_error(http_api.native_failure),
        )
        Ok(
          http_api.raw(200, value)
          |> response.set_header("etag", http_api.etag(value)),
        )
      }
      _ -> {
        use _ <- result.try(http_api.empty_body(req))
        use _ <- result.try(
          oauth.cancel_identified(config.home, id, logins)
          |> result.map_error(http_api.native_failure),
        )
        Ok(
          response.new(204)
          |> response.set_body(mist.Bytes(bytes_tree.new()))
          |> response.set_header("cache-control", "no-store"),
        )
      }
    }
  }
  http_api.answer(outcome)
}

pub fn account(
  config: Config,
  registry: Subject(Message),
  id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use _ <- result.try(http_api.json_parameters(req, []))
    use _ <- result.try(http_api.empty_body(req))
    let logins = actor.call(registry, 5000, Logins)
    use _ <- result.try(
      oauth.remove_account(config.home, logins, id)
      |> result.map_error(http_api.native_failure),
    )
    Ok(
      response.new(204)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
      |> response.set_header("cache-control", "no-store"),
    )
  }
  http_api.answer(outcome)
}

fn resolve_global_capabilities(
  home: String,
  host: runtime.Runtime,
  submitted: String,
) -> Result(String, String) {
  let decoder = {
    use id <- decode.field("catalog_session_id", decode.string)
    use revision <- decode.field("catalog_revision", decode.string)
    use choices <- decode.field(
      "choices",
      decode.dict(decode.string, decode.optional(decode.bool)),
    )
    decode.success(#(id, revision, choices))
  }
  use #(id, revision, choices) <- result.try(
    json.parse(submitted, decoder)
    |> result.replace_error("invalid capability choices"),
  )
  use catalog <- result.try(session_catalog.inspect(
    home,
    runtime.inventory(host),
    id,
  ))
  use _ <- result.try(case catalog.revision == revision {
    True -> Ok(Nil)
    False -> Error("catalog changed; refresh before changing a capability")
  })
  use resolved <- result.try(
    list.try_map(dict.to_list(choices), fn(choice) {
      use candidate <- result.try(
        list.find(catalog.candidates, fn(candidate) { candidate.id == choice.0 })
        |> result.replace_error("candidate was not found"),
      )
      use key <- result.try(option.to_result(
        candidate.preference_key,
        "candidate has no preference key",
      ))
      use kind <- result.try(case candidate.kind {
        "skill" -> Ok("skills")
        "instruction" -> Ok("instructions")
        "mcp" -> Ok("mcp")
        _ -> Error("extension defaults belong to the extensions settings group")
      })
      use _ <- result.try(case choice.1 {
        Some(True) ->
          case candidate.valid && candidate.shadowed_by == None {
            True -> Ok(Nil)
            False -> Error("candidate is invalid or shadowed")
          }
        _ -> Ok(Nil)
      })
      Ok(#(kind, key, choice.1))
    }),
  )
  Ok(
    json.object(
      list.map(["skills", "instructions", "mcp"], fn(kind) {
        #(
          kind,
          json.object(
            list.filter_map(resolved, fn(change) {
              case change.0 == kind {
                True -> Ok(#(change.1, json.nullable(change.2, json.bool)))
                False -> Error(Nil)
              }
            }),
          ),
        )
      }),
    )
    |> json.to_string,
  )
}
