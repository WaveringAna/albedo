//// One `web_search` for the model over every provider extension that can
//// search: the user's preferred provider from the `/web-search` page
//// searches, and only when it fails does the query fall back to the next.

import albedo/harness/client_api
import albedo/harness/command
import albedo/harness/extension
import albedo/harness/extensions/web_search/order
import albedo/harness/extensions/web_search/service
import albedo/harness/host
import albedo/harness/rpc
import albedo/harness/web_search
import gleam/bool
import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/list
import gleam/result
import gleam/string

pub fn extension() -> extension.Extension {
  extension.Extension(
    "web-search",
    "Web search for the model through the signed-in providers, in the order chosen on /web-search",
    ["python"],
    [
      extension.ToolPlugin(instructions, [], ["web_search"], [
        #("web_search", fn(context: host.Context, request) {
          handle(context.searches, context.session, request)
        }),
      ]),
      extension.CommandPlugin([
        command.resource(
          "/web-search",
          "Choose which web search providers the model uses, and in what order.",
          [],
        ),
      ]),
      extension.ClientPlugin([
        client_api.Command(
          "/web-search",
          client_api.Read,
          [],
          client_api.operation_defaults(
            "listWebSearchProviders",
            http.Get,
            service.collection,
            200,
          ),
        ),
      ]),
      extension.ServicePlugin(
        extension.Service(
          fn(_, _) { extension.Admission(extension.DaemonToken, 4096) },
          fn(daemon, path, req, _) {
            service.handle(daemon.searches(), path, req)
          },
        ),
      ),
    ],
    extension.no_initialise,
  )
}

const instructions =
  "await web_search(query, limit=8) searches the web. It returns a record with answer (a written answer, possibly empty) and sources, each with title, url, snippet, and published; printing it shows both. Use it for anything that may have changed since you were trained: releases, docs, changelogs, errors other people hit."

fn handle(
  providers: List(web_search.Provider),
  session: String,
  request: String,
) -> String {
  rpc.serve(
    request,
    #("invalid", "invalid web search request"),
    fn(method, args) {
      case method {
        "web_search.search" -> {
          let decoder = {
            use text <- decode.field("query", decode.string)
            use limit <- decode.optional_field("limit", 8, decode.int)
            decode.success(web_search.Query(text, limit, session))
          }
          use query <- result.try(
            rpc.args(args, decoder, #(
              "invalid",
              "web_search takes a query string and an integer limit",
            )),
          )
          use <- bool.guard(
            string.trim(query.text) == "",
            Error(#("invalid", "the query is empty")),
          )
          use <- bool.guard(
            query.limit < 1 || query.limit > 50,
            Error(#("invalid", "limit must be 1..50")),
          )
          use preference <- result.try(
            order.load() |> result.map_error(fn(error) { #("settings", error) }),
          )
          search(order.tried(order.ranked(providers, preference)), query, [])
        }
        _ -> Error(#("invalid", "unknown host operation"))
      }
    },
    fn(failure) { failure },
  )
}

/// The preferred provider's answer, falling back down the list only when a
/// provider fails or finds nothing; every failure when all of them do.
fn search(
  providers: List(web_search.Provider),
  query: web_search.Query,
  skipped: List(#(String, String)),
) -> Result(json.Json, #(String, String)) {
  case providers {
    [] -> Error(#("unavailable", exhausted(list.reverse(skipped))))
    [provider, ..rest] ->
      case provider.search(query) {
        Ok(web_search.Answer("", [])) ->
          search(rest, query, [#(provider.name, "found nothing"), ..skipped])
        Ok(answer) -> Ok(answered(answer))
        Error(reason) ->
          search(rest, query, [#(provider.name, reason), ..skipped])
      }
  }
}

fn exhausted(skipped: List(#(String, String))) -> String {
  case skipped {
    [] -> "no web search provider is on; turn one on in /web-search"
    _ ->
      "every web search provider failed: "
      <> skipped
      |> list.map(fn(entry) { entry.0 <> ": " <> entry.1 })
      |> string.join("; ")
  }
}

fn answered(answer: web_search.Answer) -> json.Json {
  json.object([
    #("answer", json.string(answer.text)),
    #(
      "sources",
      json.array(answer.sources, fn(source) {
        json.object([
          #("title", json.string(source.title)),
          #("url", json.string(source.url)),
          #("snippet", json.string(source.snippet)),
          #("published", json.nullable(source.published, json.string)),
        ])
      }),
    ),
  ])
}
