//// Daemon catalogs, workspace browsing, host observations, and storage reports.

import albedo/daemon/configuration
import albedo/daemon/folders
import albedo/daemon/hosts
import albedo/daemon/http_api
import albedo/daemon/http_wire
import albedo/daemon/registry.{type Config, type Message, List}
import albedo/daemon/session_provider
import albedo/daemon/storage_report
import albedo/daemon/usage
import albedo/harness/cache_ttl
import albedo/harness/extension
import albedo/harness/location
import albedo/harness/runtime
import albedo/harness/ssh
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/uri
import mist

pub fn hosts(
  config: Config,
  registry: Subject(Message),
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(
      http_api.json_parameters(req, ["target", "limit", "next"]),
    )
    use limit <- result.try(http_api.limit_parameter(parameters, 50))
    let sessions = actor.call(registry, 5000, List)
    let targets = case list.key_find(parameters, "target") {
      Ok(target) -> [target]
      Error(_) -> hosts.targets(sessions)
    }
    let revision =
      http_api.etag(json.to_string(json.array(targets, json.string)))
    use offset <- result.try(http_api.page_offset(
      config.token,
      req,
      parameters,
      revision,
      0,
    ))
    let shown = list.drop(targets, offset) |> list.take(limit)
    let next = case offset + list.length(shown) < list.length(targets) {
      True ->
        http_api.continuation(
          config.token,
          req,
          parameters,
          revision,
          offset + list.length(shown),
        )
      False -> json.null()
    }
    Ok(http_api.reply(
      200,
      json.object([
        #(
          "items",
          json.array(shown, fn(target) {
            http_api.host(ssh.observe(target, False))
          }),
        ),
        #("next", next),
      ]),
    ))
  }
  http_api.answer(outcome)
}

pub fn probe(
  target: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use _ <- result.try(http_api.json_parameters(req, []))
    use _ <- result.try(http_api.empty_body(req))
    use _ <- result.try(
      location.parse(target <> ":/")
      |> result.replace(Nil)
      |> result.map_error(http_api.invalid),
    )
    Ok(http_api.reply(202, http_api.host(ssh.observe(target, True))))
  }
  http_api.answer(outcome)
}

fn folder_failure(failure: folders.Failure) -> http_api.Failure {
  let detail =
    json.parse(
      json.to_string(failure.1),
      decode.field("error", decode.string, decode.success),
    )
    |> result.unwrap("workspace is unavailable")
  http_api.Failure(failure.0, "workspace_unavailable", detail)
}

pub fn workspaces(
  config: Config,
  registry: Subject(Message),
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(
      http_api.json_parameters(req, ["location", "include", "limit", "next"]),
    )
    use limit <- result.try(http_api.limit_parameter(parameters, 50))
    case list.key_find(parameters, "location") {
      Error(_) -> {
        use _ <- result.try(case list.key_find(parameters, "include") {
          Error(_) -> Ok(Nil)
          _ -> Error(http_api.invalid("include=preview requires location"))
        })
        let sessions = actor.call(registry, 5000, List)
        let workspaces =
          list.fold(sessions, dict.new(), fn(workspaces, info) {
            dict.upsert(workspaces, info.cwd, fn(prior) {
              case prior {
                None -> #(1, info.last_assistant_at)
                Some(#(count, at)) -> #(
                  count + 1,
                  case at, info.last_assistant_at {
                    Some(old), Some(next) -> Some(int.max(old, next))
                    None, next -> next
                    old, _ -> old
                  },
                )
              }
            })
          })
          |> dict.to_list
          |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
        let revision = http_api.etag(string.inspect(workspaces))
        use offset <- result.try(http_api.page_offset(
          config.token,
          req,
          parameters,
          revision,
          0,
        ))
        let shown = list.drop(workspaces, offset) |> list.take(limit)
        let next = case offset + list.length(shown) < list.length(workspaces) {
          True ->
            http_api.continuation(
              config.token,
              req,
              parameters,
              revision,
              offset + list.length(shown),
            )
          False -> json.null()
        }
        Ok(http_api.reply(
          200,
          json.object([
            #(
              "items",
              json.array(shown, fn(entry) {
                json.object([
                  #("location", json.string(entry.0)),
                  #("use_count", json.int(entry.1.0)),
                  #(
                    "activity_at",
                    json.nullable(entry.1.1, fn(seconds) {
                      http_wire.timestamp(seconds * 1000)
                    }),
                  ),
                ])
              }),
            ),
            #("next", next),
          ]),
        ))
      }
      Ok(at) -> {
        use directory <- result.try(
          folders.directory(at) |> result.map_error(folder_failure),
        )
        let revision = http_api.etag(string.inspect(directory))
        use offset <- result.try(http_api.page_offset(
          config.token,
          req,
          parameters,
          revision,
          0,
        ))
        let shown = list.drop(directory.items, offset) |> list.take(limit)
        let next = case
          offset + list.length(shown) < list.length(directory.items)
        {
          True ->
            http_api.continuation(
              config.token,
              req,
              parameters,
              revision,
              offset + list.length(shown),
            )
          False -> json.null()
        }
        let host =
          location.parse(directory.location)
          |> result.map(location.ssh_target)
          |> result.unwrap(Error(Nil))
          |> option.from_result
        let fields = [
          #("directory", json.string(directory.location)),
          #("parent", json.nullable(directory.parent, json.string)),
          #("home", json.string(directory.home)),
          #(
            "host",
            json.nullable(host, fn(target) {
              http_api.host(ssh.observe(target, False))
            }),
          ),
          #(
            "items",
            json.array(shown, fn(item) {
              json.object([
                #("name", json.string(item.name)),
                #("location", json.string(item.location)),
                #("vcs", json.nullable(item.vcs, json.string)),
                #("modified_at", http_wire.timestamp(item.modified * 1000)),
                #("hidden", json.bool(item.hidden)),
              ])
            }),
          ),
          #("next", next),
        ]
        use fields <- result.try(case list.key_find(parameters, "include") {
          Error(_) -> Ok(fields)
          Ok("preview") ->
            folders.observe_preview(directory.location)
            |> result.map_error(folder_failure)
            |> result.map(fn(preview) {
              [
                #(
                  "preview",
                  http_wire.workspace_preview(preview, directory.location),
                ),
                ..fields
              ]
            })
          _ -> Error(http_api.invalid("unknown workspace include"))
        })
        Ok(http_api.reply(200, json.object(fields)))
      }
    }
  }
  http_api.answer(outcome)
}

pub fn models(
  config: Config,
  registry: Subject(Message),
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(
      http_api.json_parameters(req, [
        "view",
        "extension",
        "host",
        "model",
        "provider_profile",
        "provider",
        "endpoint",
        "limit",
        "next",
      ]),
    )
    use limit <- result.try(http_api.limit_parameter(parameters, 50))
    let view = list.key_find(parameters, "view") |> result.unwrap("catalogue")
    case view {
      "cache-policy" -> {
        use _ <- result.try(
          case
            list.any(parameters, fn(pair) {
              list.contains(
                ["provider", "provider_profile", "endpoint"],
                pair.0,
              )
            })
          {
            True ->
              Error(http_api.invalid(
                "cache-policy does not accept provider parameters",
              ))
            False -> Ok(Nil)
          },
        )
        let table = cache_ttl.table()
        let revision =
          http_api.etag(json.to_string(cache_ttl.table_json(table)))
        use offset <- result.try(http_api.page_offset(
          config.token,
          req,
          parameters,
          revision,
          0,
        ))
        let shown = list.drop(table.entries, offset) |> list.take(limit)
        let next = case
          offset + list.length(shown) < list.length(table.entries)
        {
          True ->
            http_api.continuation(
              config.token,
              req,
              parameters,
              revision,
              offset + list.length(shown),
            )
          False -> json.null()
        }
        let matched =
          cache_ttl.lookup(
            list.key_find(parameters, "extension") |> result.unwrap(""),
            list.key_find(parameters, "host") |> result.unwrap(""),
            list.key_find(parameters, "model") |> result.unwrap(""),
          )
        Ok(http_api.reply(
          200,
          json.object([
            #("entries", json.array(shown, cache_ttl.entry_json)),
            #(
              "layers",
              json.array(table.layers, fn(layer) {
                json.object([
                  #("name", json.string(layer.name)),
                  #("path", json.string(layer.path)),
                  #("loaded", json.bool(layer.loaded)),
                  #(
                    "error",
                    json.nullable(layer.error, fn(detail) {
                      http_api.reason("cache_policy_layer_failed", detail)
                    }),
                  ),
                ])
              }),
            ),
            #("matched", json.nullable(matched, cache_ttl.entry_json)),
            #("next", next),
          ]),
        ))
      }
      "catalogue" -> {
        use _ <- result.try(
          case
            list.any(parameters, fn(pair) {
              list.contains(["extension", "host"], pair.0)
            })
          {
            True ->
              Error(http_api.invalid(
                "catalogue does not accept cache selectors",
              ))
            False -> Ok(Nil)
          },
        )
        use host <- result.try(
          registry.host(registry) |> result.map_error(http_api.failure),
        )
        use provider <- result.try(
          case
            list.key_find(parameters, "provider_profile"),
            list.key_find(parameters, "provider"),
            list.key_find(parameters, "endpoint")
          {
            Ok(profile), Error(_), Error(_) ->
              configuration.named(config.home, profile)
              |> result.map(fn(profile) {
                #(
                  profile.extension,
                  session_provider.profile_endpoint(config.home, profile.name),
                )
              })
              |> result.map_error(http_api.failure)
            Error(_), Ok(provider), endpoint ->
              Ok(#(provider, option.from_result(endpoint)))
            _, _, _ ->
              Error(http_api.invalid(
                "choose exactly one of provider_profile or provider; endpoint requires provider",
              ))
          },
        )
        let models = case list.key_find(parameters, "model") {
          Error(_) -> runtime.listed_models(host, provider.0, provider.1)
          Ok(id) -> {
            let info =
              extension.model_info(
                runtime.global(host) |> result.unwrap([]),
                id,
                provider.1,
              )
            [
              runtime.ListedModel(
                id,
                info,
                option.map(info, fn(info) { info.efforts }) |> option.unwrap([]),
              ),
            ]
          }
        }
        let encoded = json.array(models, model_json(_, provider.0, provider.1))
        let revision = http_api.etag(json.to_string(encoded))
        use offset <- result.try(http_api.page_offset(
          config.token,
          req,
          parameters,
          revision,
          0,
        ))
        let shown = list.drop(models, offset) |> list.take(limit)
        let next = case offset + list.length(shown) < list.length(models) {
          True ->
            http_api.continuation(
              config.token,
              req,
              parameters,
              revision,
              offset + list.length(shown),
            )
          False -> json.null()
        }
        Ok(http_api.reply(
          200,
          json.object([
            #("items", json.array(shown, model_json(_, provider.0, provider.1))),
            #("next", next),
          ]),
        ))
      }
      _ -> Error(http_api.invalid("unknown model view"))
    }
  }
  http_api.answer(outcome)
}

fn model_json(
  model: runtime.ListedModel,
  provider: String,
  endpoint: Option(String),
) -> json.Json {
  let fact = fn(read) { option.then(model.info, read) }
  let host =
    option.then(endpoint, fn(endpoint) {
      uri.parse(endpoint)
      |> result.map(fn(uri) { uri.host })
      |> result.unwrap(None)
    })
    |> option.unwrap("")
  let policy = cache_ttl.lookup(provider, host, model.id)
  let ttl =
    option.then(policy, cache_ttl.clock_tier)
    |> option.map(fn(tier) { tier.seconds })
  json.object([
    #("id", json.string(model.id)),
    #("label", json.string(model.id)),
    #(
      "efforts",
      json.array(model.efforts, fn(effort) {
        json.object([
          #("id", json.string(effort)),
          #("label", json.string(effort)),
        ])
      }),
    ),
    #(
      "default_context_tokens",
      json.nullable(fact(fn(info) { info.context_tokens }), json.int),
    ),
    #(
      "effective_context_tokens",
      json.nullable(fact(extension.window), json.int),
    ),
    #(
      "max_context_tokens",
      json.nullable(fact(fn(info) { info.max_context_tokens }), json.int),
    ),
    #(
      "max_output_tokens",
      json.nullable(fact(fn(info) { info.max_output_tokens }), json.int),
    ),
    #(
      "input_modalities",
      json.array(
        option.map(model.info, fn(info) { info.input_modalities })
          |> option.unwrap([]),
        json.string,
      ),
    ),
    #("image_edge", json.null()),
    #("raised", json.bool(list.contains(extension.raised_caps(), model.id))),
    #("cap_key", json.string(model.id)),
    #(
      "cache_policy",
      json.object([
        #("ttl_seconds", json.nullable(ttl, json.int)),
        #(
          "source",
          json.nullable(
            option.map(policy, fn(policy) { policy.source }),
            json.string,
          ),
        ),
      ]),
    ),
    #(
      "source",
      json.string(
        option.map(model.info, fn(info) { info.source })
        |> option.unwrap("unknown"),
      ),
    ),
    #("observed_at", json.null()),
  ])
}

pub fn storage(
  config: Config,
  registry: Subject(Message),
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(
      http_api.json_parameters(req, ["limit", "sessions_next", "files_next"]),
    )
    use limit <- result.try(http_api.limit_parameter(parameters, 50))
    use host <- result.try(
      registry.host(registry) |> result.map_error(http_api.failure),
    )
    use observed <- result.try(
      storage_report.observe(runtime.ledger(host), config.home)
      |> result.map_error(http_api.failure),
    )
    let revision = http_api.etag(string.inspect(observed.database.sessions))
    let base = list.filter(parameters, fn(pair) { pair.0 == "limit" })
    let session_parameters = case list.key_find(parameters, "sessions_next") {
      Ok(token) -> [#("next", token), ..base]
      Error(_) -> base
    }
    use offset <- result.try(http_api.page_offset(
      config.token,
      req,
      session_parameters,
      "sessions" <> revision,
      0,
    ))
    let db = observed.database
    let files = observed.files
    let shown = list.drop(db.sessions, offset) |> list.take(limit)
    let next = case offset + list.length(shown) < list.length(db.sessions) {
      True ->
        http_api.continuation(
          config.token,
          req,
          base,
          "sessions" <> revision,
          offset + list.length(shown),
        )
      False -> json.null()
    }
    let total =
      list.fold(db.sessions, 0, fn(sum, session) { sum + session.bytes })
    let file_items =
      list.map(files.old_kernels, fn(file) { #(file, "kernel", "old_kernel") })
      |> list.append(
        list.map(files.old_backups, fn(file) { #(file, "backup", "old_backup") }),
      )
    let file_revision = http_api.etag(string.inspect(file_items))
    let file_parameters = case list.key_find(parameters, "files_next") {
      Ok(token) -> [#("next", token), ..base]
      Error(_) -> base
    }
    use file_offset <- result.try(http_api.page_offset(
      config.token,
      req,
      file_parameters,
      "files" <> file_revision,
      0,
    ))
    let file_shown = list.drop(file_items, file_offset) |> list.take(limit)
    let files_next = case
      file_offset + list.length(file_shown) < list.length(file_items)
    {
      True ->
        http_api.continuation(
          config.token,
          req,
          base,
          "files" <> file_revision,
          file_offset + list.length(file_shown),
        )
      False -> json.null()
    }
    Ok(http_api.reply(
      200,
      json.object([
        #(
          "database",
          json.object([
            #("main_file_bytes", json.int(files.database)),
            #("wal_bytes", json.int(files.wal)),
            #("page_size_bytes", json.int(db.page_size)),
            #("page_count", json.int(db.page_count)),
            #("free_page_count", json.int(db.free_pages)),
            #(
              "used_bytes",
              json.int({ db.page_count - db.free_pages } * db.page_size),
            ),
          ]),
        ),
        #(
          "sessions",
          json.object([
            #(
              "items",
              json.array(shown, fn(session) {
                json.object([
                  #("id", json.string(session.id)),
                  #("title", json.string(session.title)),
                  #("workspace", json.string(session.workspace)),
                  #(
                    "created_at",
                    json.nullable(session.created_at, http_wire.timestamp),
                  ),
                  #(
                    "activity_at",
                    json.nullable(session.activity_at, http_wire.timestamp),
                  ),
                  #("estimated_content_bytes", json.int(session.bytes)),
                ])
              }),
            ),
            #("next", next),
            #("total_count", json.int(list.length(db.sessions))),
            #("total_estimated_content_bytes", json.int(total)),
          ]),
        ),
        #(
          "images",
          json.object([
            #("count", json.int(db.image_count)),
            #("bytes", json.int(db.images)),
          ]),
        ),
        #(
          "files",
          json.object([
            #(
              "items",
              json.array(file_shown, fn(item) {
                json.object([
                  #("path", json.string(item.0.path)),
                  #("category", json.string(item.1)),
                  #("bytes", json.int(item.0.bytes)),
                  #("modified_at", json.null()),
                  #("cleanup_candidate", json.bool(True)),
                  #("cleanup_reason", json.string(item.2)),
                ])
              }),
            ),
            #("next", files_next),
            #(
              "totals",
              json.object([
                #("kernel_bytes", json.int(files.kernels)),
                #("backup_bytes", json.int(files.backups)),
                #("other_bytes", json.int(files.other)),
                #("recent_backup_bytes", json.int(files.recent_backups)),
                #("recent_backup_count", json.int(files.recent_backup_count)),
              ]),
            ),
          ]),
        ),
        #("measured_at", http_wire.timestamp(usage.now())),
      ]),
    ))
  }
  http_api.answer(outcome)
}
