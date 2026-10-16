//// OpenCode Zen provider over Chat Completions.
////
//// Zen serves one gateway's models, free tier included. A paid model goes out
//// with the profile's own key. A free-lane model is answered only for a
//// request shaped like the one OpenCode's own client sends: the client's
//// identity headers, a session id in the shape it mints, `stream: true`, and a
//// tool list that carries the names its agent sends (see
//// `shape_for_free_lane`). Everything else about the request, albedo's own
//// system prompt and tools included, is albedo's.

import albedo/harness/extension
import albedo/harness/extensions/opencode_go/wire
import albedo/harness/extensions/opencode_zen/catalog
import albedo/harness/rotation
import albedo/openai_api
import albedo/openai_api/types
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const provider_name = "opencode-zen"

/// The tool names the free lane's fingerprint carries. It reads the names and
/// nothing else — descriptions and schemas go uninspected — so these are
/// reserved stubs the model is told never to call.
const gate_tool_names = ["bash", "glob", "grep", "read"]

pub fn extension() -> extension.Extension {
  extension.Extension(
    provider_name,
    "OpenCode Zen gateway via its API key, with live model discovery, the free tier's `-free` models included",
    ["models"],
    [
      extension.ModelsPlugin(catalog.catalog()),
      extension.ModelProviderPlugin(extension.ModelProvider(
        provider_name,
        resolve,
      )),
    ],
    extension.no_initialise,
  )
}

fn resolve(
  context: extension.ModelContext,
) -> Option(Result(extension.Upstream, String)) {
  use <- rotation.require_provider(
    context,
    provider_name,
    "OpenCode Zen",
    types.ChatCompletions,
  )
  use #(base_url, api_key) <- result.try(native_access(
    context.home,
    context.profile,
  ))
  case string.trim(base_url) {
    "" -> Error("OpenCode Zen base URL is invalid")
    _ -> {
      // Which identity the request wears is decided here, where the model is
      // known: only a free-lane request asks for OpenCode's.
      let free = free_lane(context.model, api_key)
      let client =
        openai_api.opencode_zen_client(
          base_url,
          case free {
            True -> "public"
            False -> api_key
          },
          native_session(context.session),
          native_project(context.home),
          native_user_agent(),
        )
      Ok(upstream(client, free))
    }
  }
}

/// Whether a request on `model` goes out on the free lane: one of the models
/// the lane serves, or any model at all on a profile carrying no credential,
/// since the free lane is the only one reachable without one. Zen serves a few
/// models free without saying so in the id — `big-pickle` is the one that does
/// today — and a paid model picked without a credential can only fail on the
/// credential anyway, which is what its 401 says.
pub fn free_lane(model: String, api_key: String) -> Bool {
  native_free(model) || string.trim(api_key) == ""
}

/// An upstream served by the shared OpenAI-compatible stream, shaped for the
/// free lane when it is a free-tier model.
fn upstream(client: types.Client, free: Bool) -> extension.Upstream {
  extension.Upstream(
    client.base_url,
    client.protocol,
    fn(request, on_event) { stream(client, free, request, on_event) },
    explain,
    fn() { None },
    fn(_) { [] },
    types.any_images,
  )
}

/// Streams `request` on the route its model speaks. Zen serves its
/// contributor models on the Responses route only — they answer 400 to a
/// Chat Completions request — and everything else on Chat Completions.
fn stream(
  client: types.Client,
  free: Bool,
  request: types.Request,
  on_event: fn(types.Event) -> types.Control,
) -> Result(types.Turn, types.Error) {
  case responses_only(request.model) {
    True -> {
      // Zen's Responses half takes `tool_choice: auto` on the free lane and
      // nothing else, and it reads a tool marked strict by strict's own rules
      // — every property required — which albedo's optional parameters do not
      // meet. It validates the flag, not the schema, so the flag goes off.
      let request =
        loose_tools(case free {
          True ->
            types.Request(
              ..shape_for_free_lane(request),
              options: types.Options(
                ..request.options,
                tool_choice: Some(types.AutoTool),
              ),
            )
          False -> request
        })
      use exchange <- result.try(wire.encode_responses(client, request))
      openai_api.exchange(exchange, wire.responses_reducer(), on_event)
    }
    False ->
      openai_api.stream(
        client,
        case free {
          True -> shape_for_free_lane(request)
          False -> request
        },
        on_event,
      )
  }
}

/// Whether `model` is served on the Responses route.
fn responses_only(model: String) -> Bool {
  string.starts_with(string.lowercase(string.trim(model)), "muse-spark-")
}

/// `request` with every tool's strictness turned off, whatever the tool asked
/// for. Zen's Responses route reads the flag as declaring that the schema
/// follows strict's rules, which an optional parameter does not.
fn loose_tools(request: types.Request) -> types.Request {
  types.Request(
    ..request,
    tools: list.map(request.tools, fn(tool) {
      types.Tool(..tool, strict: False)
    }),
  )
}

/// `request` with the free lane's fingerprint tools appended. A request whose
/// own tool list already carries them is left alone; albedo's tool names never
/// do, so in practice this appends the quartet.
pub fn shape_for_free_lane(request: types.Request) -> types.Request {
  let present =
    request.tools
    |> list.map(fn(tool) { tool.name })
  let missing =
    gate_tool_names
    |> list.filter(fn(name) { !list.contains(present, name) })
  case missing {
    [] -> request
    _ ->
      types.Request(
        ..request,
        tools: list.append(request.tools, list.map(missing, gate_tool)),
      )
  }
}

/// One reserved stub. It is never meant to be called, and saying so is what
/// keeps a model from calling it.
fn gate_tool(name: String) -> types.Tool {
  types.Tool(
    name,
    "Reserved by the client harness; never call this tool.",
    json.object([
      #("type", json.string("object")),
      #("properties", json.object([])),
    ]),
    False,
  )
}

fn explain(error: types.Error) -> Option(String) {
  case error {
    types.HttpError(401, _) ->
      Some(
        "OpenCode Zen rejected the credential; save an API key for this profile or set OPENCODE_ZEN_API_KEY",
      )
    types.HttpError(403, body) ->
      Some(
        "OpenCode Zen refused this request"
        <> case string.contains(body, "FreeTierError") {
          True ->
            ": its free tier answers only a request shaped like OpenCode's own client — its identity headers, a `ses_` session id, streaming, and its tool names. Something in this request's shape was not accepted"
          False -> ": " <> rotation.error_message(body)
        },
      )
    types.HttpError(429, body) ->
      Some(
        "OpenCode Zen rate limited this request: "
        <> rotation.error_message(body),
      )
    types.HttpError(status, body) ->
      Some(
        "OpenCode Zen error ("
        <> int.to_string(status)
        <> "): "
        <> rotation.error_message(body),
      )
    _ -> None
  }
}

@external(erlang, "albedo_opencode_zen", "access")
fn native_access(
  home: String,
  profile: String,
) -> Result(#(String, String), String)

@external(erlang, "albedo_opencode_zen", "session")
fn native_session(seed: String) -> String

@external(erlang, "albedo_opencode_zen", "project")
fn native_project(home: String) -> String

@external(erlang, "albedo_opencode_zen", "user_agent")
fn native_user_agent() -> String

@external(erlang, "albedo_opencode_zen", "free")
fn native_free(model: String) -> Bool
