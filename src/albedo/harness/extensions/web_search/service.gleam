//// The `/web-search` page: the providers in the order a search tries them,
//// each one moved up or down, or turned off and on.

import albedo/daemon/bus
import albedo/daemon/http_api as api
import albedo/harness/client_api
import albedo/harness/extensions/web_search/order
import albedo/harness/web_search
import gleam/bool
import gleam/dynamic/decode
import gleam/http.{Get, Post}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import mist

pub const collection = "/extensions/web-search/providers"

pub fn handle(
  providers: Result(List(web_search.Provider), String),
  path: List(String),
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let response = {
    use providers <- result.try(
      providers
      |> result.map_error(fn(error) {
        api.Failure(503, "settings_failed", error)
      }),
    )
    dispatch(providers, path, req)
  }
  case response {
    Ok(response) -> response
    Error(error) -> api.fail(error)
  }
}

fn dispatch(
  providers: List(web_search.Provider),
  path: List(String),
  req: request.Request(BitArray),
) -> Result(response.Response(mist.ResponseData), api.Failure) {
  use ranked <- result.try(
    order.load()
    |> result.map(order.ranked(providers, _))
    |> result.map_error(fn(error) { api.Failure(503, "settings_failed", error) }),
  )
  case req.method, path {
    Get, ["providers"] -> {
      let entries = list.index_map(ranked, fn(entry, index) { #(entry, index) })
      Ok(api.reply(
        200,
        json.object([
          #(
            "items",
            json.array(entries, fn(entry) { resource(entry.0, entry.1) }),
          ),
          #("next", json.null()),
          #("page", page(entries)),
        ]),
      ))
    }
    Post, ["providers", name] -> {
      use change <- result.try(
        api.body(req, ["change"], {
          use change <- decode.field("change", decode.string)
          case change {
            "up" -> decode.success(order.Up)
            "down" -> decode.success(order.Down)
            "toggle" -> decode.success(order.Toggle)
            _ -> decode.failure(order.Toggle, "change")
          }
        }),
      )
      use changed <- result.try(
        order.apply(ranked, name, change)
        |> result.map_error(fn(refusal) {
          case refusal {
            order.Unknown ->
              api.Failure(
                404,
                "not_found",
                "no web search provider is called " <> name,
              )
            order.Unsaved(reason) -> api.Failure(503, "settings_failed", reason)
          }
        }),
      )
      bus.invalidate([collection], [], True)
      let changed =
        list.index_map(changed, fn(entry, index) { #(entry, index) })
      use #(entry, index) <- result.try(
        list.find(changed, fn(item) { { item.0 }.provider.name == name })
        |> result.replace_error(api.Failure(404, "not_found", name)),
      )
      Ok(api.reply(200, json.object([#("resource", resource(entry, index))])))
    }
    _, ["providers"] | _, ["providers", _] ->
      Error(api.Failure(
        405,
        "method_not_allowed",
        "unsupported web search method",
      ))
    _, _ ->
      Error(api.Failure(404, "not_found", "web search resource not found"))
  }
}

fn resource(entry: order.Ranked, index: Int) -> json.Json {
  json.object([
    #("url", json.string(collection <> "/" <> entry.provider.name)),
    #(
      "etag",
      json.string(
        "\"web-search-"
        <> entry.provider.name
        <> "-"
        <> int.to_string(index + 1)
        <> "-"
        <> bool.to_string(entry.on)
        <> "\"",
      ),
    ),
    #(
      "value",
      json.object([
        #("name", json.string(entry.provider.name)),
        #("label", json.string(entry.provider.label)),
        #("position", json.int(index + 1)),
        #("enabled", json.bool(entry.on)),
      ]),
    ),
  ])
}

fn page(entries: List(#(order.Ranked, Int))) -> json.Json {
  client_api.page(client_api.Page(
    title: "web search",
    summary: "the top provider searches; each one below is a fallback for when those above fail",
    empty_state: "no extension offers web search",
    glance: None,
    actions: [
      change("up", "move up", "u"),
      change("down", "move down", "d"),
      change("toggle", "turn on or off", "t"),
    ],
    rows: list.map(entries, fn(entry) {
      let #(ranked, index) = entry
      client_api.PageRow(
        id: ranked.provider.name,
        text: ranked.provider.label,
        badge: Some(case ranked.on {
          True -> int.to_string(index + 1)
          False -> "off"
        }),
        tone: case ranked.on {
          True -> "active"
          False -> "muted"
        },
        detail: None,
        resource: resource(ranked, index),
      )
    }),
  ))
}

fn change(id: String, label: String, key: String) -> client_api.Action {
  client_api.Action(
    id: id,
    label: label,
    keyboard_hint: key,
    confirmation: None,
    fields: [],
    operation: client_api.Operation(
      ..client_api.operation_defaults(
        "changeWebSearchProvider",
        Post,
        collection <> "/{name}",
        200,
      ),
      path: [#("name", client_api.Row("/resource/value/name"))],
      body: [#("/change", client_api.Literal(json.string(id)))],
    ),
  )
}
