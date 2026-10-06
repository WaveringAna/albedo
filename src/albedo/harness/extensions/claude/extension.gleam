//// Claude over Anthropic Messages: a subscription through Claude Code OAuth,
//// or a Console API key set as the profile's `apiKey`.

import albedo/daemon/configuration
import albedo/harness/extension
import albedo/harness/extensions/claude/catalog
import albedo/harness/extensions/claude/search as claude_search
import albedo/harness/extensions/claude/stream
import albedo/harness/extensions/claude/wire
import albedo/harness/extensions/models/extension as models
import albedo/harness/oauth
import albedo/harness/rotation
import albedo/harness/settings
import albedo/harness/web_search
import albedo/openai_api
import albedo/openai_api/types
import gleam/bool
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

const endpoint = "https://api.anthropic.com"

const client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

const scope =
  "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

pub fn extension() -> extension.Extension {
  extension.Extension(
    "claude",
    "Claude Pro/Max via Claude Code OAuth, or a Console API key, over Anthropic Messages",
    ["models"],
    [
      extension.LoginPlugin(login()),
      extension.ModelsPlugin(extension.ModelCatalog(
        lookup,
        list_models,
        Some(fn() { catalog.reload(settings.home()) }),
      )),
      extension.ModelProviderPlugin(extension.ModelProvider(
        "anthropic",
        resolve,
      )),
      extension.SearchPlugin(web_search.Provider("claude", "Claude", search)),
    ],
    extension.no_initialise,
  )
}

fn login() -> oauth.Login {
  oauth.Login(
    "claude",
    "add claude account",
    "oauth · claude pro/max",
    types.ChatCompletions,
    "anthropic",
    oauth.Callback("localhost", 53_692, "/callback", True),
    fn(grant) {
      oauth.authorize_url("https://claude.ai/oauth/authorize", [
        #("code", "true"),
        #("client_id", client_id),
        #("response_type", "code"),
        #("redirect_uri", grant.redirect),
        #("scope", scope),
        #("code_challenge", grant.challenge),
        #("code_challenge_method", "S256"),
        #("state", grant.state),
      ])
    },
    fn(grant, code, _progress) {
      native_exchange(code, grant.state, grant.verifier, grant.redirect)
    },
    native_account,
  )
}

fn resolve(
  context: extension.ModelContext,
) -> Option(Result(extension.Upstream, String)) {
  use <- rotation.require_provider(
    context,
    "claude",
    "Claude",
    types.ChatCompletions,
  )
  use auth <- result.try(authenticate(context))
  let owner = wire.owner(auth)
  Ok(extension.Upstream(
    endpoint,
    types.ChatCompletions,
    fn(request, on_event) {
      let request = with_output_limit(request)
      ensure_files(
        context.home,
        wire.auth_header(auth),
        owner,
        endpoint,
        request,
      )
      use exchange <- result.try(wire.encode(context.home, auth, request))
      let outcome =
        openai_api.exchange(
          exchange,
          stream.reducer(request.model, request.tools),
          on_event,
        )
      case outcome {
        // Drop cached file handles on 4xx so next turn heals inline.
        Error(types.HttpError(status, body)) if status >= 400 && status < 500 -> {
          reject_files(context.home, owner, body)
          outcome
        }
        _ -> outcome
      }
    },
    fn(error) {
      case error, auth {
        types.HttpError(401, _), wire.Subscription(access:, ..) -> {
          native_expire(context.home, access)
          Some(
            "Claude rejected this access token; send your message again to refresh it, or run /login",
          )
        }
        types.HttpError(401, _), wire.ApiKey(_) ->
          Some(
            "Anthropic rejected this API key; check the profile's key in /login",
          )
        _, _ -> None
      }
    },
    fn() { Some(owner) },
    wire.cache_marks,
    images,
  ))
}

/// Anthropic takes an 8000px image alone, but once a request carries more
/// than 20 images every one of them, old turns and tool results included,
/// must fit in 2000px. A working session passes 20 quickly, so that is the
/// bound an image is held to from the start. A request carries at most 100.
const images = types.ImageLimits(max_edge: 2000, max_images: Some(100))

/// `query` searched by the session's Claude account, with the model the
/// `searchModel` setting names, else the newest listed model.
fn search(query: web_search.Query) -> Result(web_search.Answer, String) {
  let home = settings.home()
  // Signed out fails here, before listing models can reach the network.
  use auth <- result.try(
    authenticate(extension.ModelContext(
      home,
      query.session,
      "",
      "claude",
      "",
      types.ChatCompletions,
      None,
    )),
  )
  use model <- result.try(case web_search.configured_model("claude") {
    Some(model) -> Ok(model)
    None ->
      list_models("anthropic", None)
      |> list.first
      |> result.replace_error("Anthropic lists no models for this account")
  })
  claude_search.run(home, auth, model, query)
}

/// A profile's `apiKey` bills the Anthropic Console; without one, the signed-in
/// Claude subscription serves the session.
fn authenticate(context: extension.ModelContext) -> Result(wire.Auth, String) {
  let api_key =
    decode.optional_field("apiKey", "", decode.string, decode.success)
  case configuration.settings(context.home, context.profile, api_key) {
    Ok(key) if key != "" -> Ok(wire.ApiKey(key))
    _ -> {
      use access <- result.try(native_access(
        context.home,
        context.session,
        context.profile,
      ))
      use #(account, device, session) <- result.map(native_profile(
        access,
        context.session,
      ))
      wire.Subscription(access, account, device, session)
    }
  }
}

/// Every model the Anthropic API lists for this account, newest first. The
/// first listing waits for the fetch; until one lands, models.dev's list.
fn list_models(provider: String, _endpoint: Option(String)) -> List(String) {
  case provider {
    "anthropic" -> {
      let home = settings.home()
      case catalog.models(home) {
        [] -> catalog.reload(home) |> result.unwrap(Nil)
        _ -> catalog.refresh_later(home)
      }
      case catalog.models(home) {
        [] -> models.list("anthropic", None)
        listed -> list.map(listed, fn(model) { model.id })
      }
    }
    _ -> []
  }
}

fn lookup(id: String, at: Option(String)) -> Option(extension.ModelInfo) {
  use <- bool.guard(
    case at {
      Some(url) -> url != endpoint
      None -> False
    },
    None,
  )
  let home = settings.home()
  case list.find(catalog.models(home), fn(model) { model.id == id }) {
    Ok(model) -> Some(listed_info(home, model))
    Error(_) -> unlisted_info(id)
  }
}

/// A turn that sets no output limit gets the model's own ceiling: Claude
/// requires `max_tokens`, and adaptive thinking spends from the same budget.
fn with_output_limit(request: types.Request) -> types.Request {
  case request.max_output_tokens {
    Some(_) -> request
    None ->
      types.Request(
        ..request,
        max_output_tokens: lookup(request.model, Some(endpoint))
          |> option.then(fn(info) { info.max_output_tokens }),
      )
  }
}

/// The API's own facts; models.dev fills in only a limit it leaves out. Its
/// efforts stand as listed, since none means the model takes no effort.
fn listed_info(home: String, model: catalog.Model) -> extension.ModelInfo {
  let info =
    extension.ModelInfo(
      ..extension.blank_model(model.id, "claude"),
      context_tokens: model.context,
      max_output_tokens: model.output,
      input_modalities: case model.images {
        True -> ["text", "image"]
        False -> ["text"]
      },
      endpoint: Some(endpoint),
      source: "Anthropic models API cached in " <> home,
    )
  extension.ModelInfo(
    ..models.complete_model(info, Some(endpoint)),
    environment: [],
    efforts: model.efforts,
  )
}

/// What models.dev knows of a model the API list does not name, such as an
/// alias a session picked before the list was fetched.
fn unlisted_info(id: String) -> Option(extension.ModelInfo) {
  use found <- option.map(models.lookup_provider("anthropic", id))
  extension.ModelInfo(
    ..found,
    provider: "claude",
    input_modalities: list.filter(found.input_modalities, fn(mode) {
      mode == "text" || mode == "image"
    }),
    endpoint: Some(endpoint),
    environment: [],
  )
}

@external(erlang, "albedo_claude_files", "ensure")
fn ensure_files(
  home: String,
  auth: #(String, String),
  owner: String,
  endpoint: String,
  request: types.Request,
) -> Nil

@external(erlang, "albedo_claude_files", "reject")
fn reject_files(home: String, owner: String, body: String) -> Nil

@external(erlang, "albedo_claude_auth", "exchange")
fn native_exchange(
  code: String,
  state: String,
  verifier: String,
  redirect: String,
) -> Result(json.Json, String)

@external(erlang, "albedo_claude_auth", "account")
fn native_account(credential: Dynamic) -> oauth.Account

@external(erlang, "albedo_claude_auth", "expire")
fn native_expire(home: String, access: String) -> Nil

@external(erlang, "albedo_claude_auth", "profile")
fn native_profile(
  access: String,
  session: String,
) -> Result(#(String, String, String), String)

@external(erlang, "albedo_claude_auth", "access")
fn native_access(
  home: String,
  session: String,
  profile: String,
) -> Result(String, String)
