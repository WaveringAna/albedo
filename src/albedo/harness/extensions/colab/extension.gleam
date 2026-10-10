//// Google Colab extension: GPU/TPU instance management and remote execution.

import albedo/harness/extension
import albedo/harness/host
import albedo/harness/oauth
import albedo/harness/rpc
import albedo/harness/settings
import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/result
import gleam/string

pub fn extension() -> extension.Extension {
  extension.Extension(
    "colab",
    "Google Colab GPU runtimes and remote execution",
    ["python", "remote"],
    [
      extension.ToolPlugin(instructions, [], ["colab"], [#("colab", route)]),
      extension.LoginPlugin(login()),
    ],
    extension.no_initialise,
  )
}

const instructions =
  "vm = await colab.launch(gpu=\"T4\", mem=\"standard\") (or gpu=\"L4\"/\"A100\", mem=\"high\")"
  <> " provisions a Google Colab GPU/TPU runtime; await colab.instances() lists active runtimes,"
  <> " and await colab.status() checks credentials."
  <> " rem = await colab.connect(vm) (or await vm.connect()) returns what remote.connect() does,"
  <> " for the VM in /content over Colab's ssh proxy; it needs an ssh public key in ~/.ssh or"
  <> " ssh_key=."
  <> " Always call await vm.stop() (or await colab.stop(vm)) when done"
  <> " to release the runtime and preserve compute units. Failures raise ColabError."

/// The kernel's `colab` binding: `colab.account` is the signed-in account's
/// access token and email, refreshed here so the kernel never reads creds.json.
fn route(_context: host.Context, request: String) -> String {
  rpc.serve(
    request,
    #("invalid", "invalid Colab request"),
    fn(method, _args) {
      case method {
        "colab.account" ->
          native_signed_in(settings.home())
          |> result.map(fn(account) {
            json.object([
              #("access", json.string(account.0)),
              #("email", json.string(account.1)),
            ])
          })
          |> result.map_error(fn(message) { #("colab", message) })
        _ -> Error(#("colab", "unknown colab operation"))
      }
    },
    fn(failure) { failure },
  )
}

pub fn login() -> oauth.Login {
  oauth.Login(
    "colab",
    "add google colab account",
    "oauth · google colab gpu runtimes",
    oauth.Service,
    "google-colab",
    oauth.Callback("127.0.0.1", 51_122, "/oauth-callback", False),
    fn(grant) {
      oauth.authorize_url("https://accounts.google.com/o/oauth2/v2/auth", [
        #("client_id", client_id()),
        #("response_type", "code"),
        #("redirect_uri", grant.redirect),
        #("scope", string.join(scopes, " ")),
        #("state", grant.state),
        #("access_type", "offline"),
        #("prompt", "consent"),
      ])
    },
    fn(grant, code, progress) {
      native_exchange(code, grant.redirect, progress)
    },
    native_account,
  )
}

const scopes = [
  "openid",
  "https://www.googleapis.com/auth/userinfo.email",
  "https://www.googleapis.com/auth/userinfo.profile",
  "https://www.googleapis.com/auth/colaboratory",
  "https://www.googleapis.com/auth/cloud-platform",
]

@external(erlang, "albedo_colab_auth", "signed_in")
fn native_signed_in(home: String) -> Result(#(String, String), String)

@external(erlang, "albedo_colab_auth", "client_id")
fn client_id() -> String

@external(erlang, "albedo_colab_auth", "exchange")
fn native_exchange(
  code: String,
  redirect: String,
  progress: fn(String) -> Nil,
) -> Result(json.Json, String)

@external(erlang, "albedo_colab_auth", "account")
fn native_account(credential: Dynamic) -> oauth.Account
