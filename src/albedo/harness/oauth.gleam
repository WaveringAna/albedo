//// Browser OAuth sign-ins that the daemon runs for every client. An extension
//// describes its provider; `albedo_oauth` owns the callback listener, the
//// race with a pasted code, and locked creds.json storage.

import albedo/openai_api/types
import gleam/dynamic.{type Dynamic}
import gleam/json.{type Json}
import gleam/uri

pub type Login {
  Login(
    /// The profile extension this sign-in serves, e.g. "codex".
    provider: String,
    label: String,
    detail: String,
    /// The protocol a profile for this provider is saved with.
    protocol: types.Protocol,
    /// The creds.json accounts key holding one account object or an array of them.
    store: String,
    callback: Callback,
    authorize: fn(Grant) -> String,
    /// Trades the code for the credential object to store. `progress`
    /// reports slow follow-up steps such as account provisioning.
    exchange: fn(Grant, String, fn(String) -> Nil) -> Result(Json, String),
    /// Names a stored credential. Equal ids are the same account.
    account: fn(Dynamic) -> Account,
  )
}

/// The loopback redirect. A fixed port fails when busy because the provider
/// allowlists that exact redirect; otherwise an ephemeral port is used.
pub type Callback {
  Callback(host: String, port: Int, path: String, fixed: Bool)
}

/// One sign-in attempt: the redirect it uses, its state nonce, and the PKCE pair.
pub type Grant {
  Grant(redirect: String, state: String, verifier: String, challenge: String)
}

pub type Account {
  Account(id: String, label: String, detail: String, selected: Bool)
}

pub type Status {
  Waiting(progress: String)
  Exchanging(progress: String)
  Done(account: String)
  Failed(reason: String)
}

@external(erlang, "albedo_oauth", "start")
pub fn start(home: String, login: Login) -> Result(#(String, String), String)

@external(erlang, "albedo_oauth", "status")
pub fn status(id: String) -> Result(Status, String)

@external(erlang, "albedo_oauth", "input")
pub fn input(id: String, text: String) -> Result(Nil, String)

@external(erlang, "albedo_oauth", "cancel")
pub fn cancel(id: String) -> Result(Nil, String)

@external(erlang, "albedo_oauth", "accounts")
pub fn accounts(home: String, login: Login) -> List(Account)

@external(erlang, "albedo_oauth", "select")
pub fn select(home: String, login: Login, id: String) -> Result(Nil, String)

@external(erlang, "albedo_oauth", "remove")
pub fn remove(home: String, login: Login, id: String) -> Result(Nil, String)

pub fn status_json(status: Status) -> Json {
  let #(state, text) = case status {
    Waiting(text) -> #("waiting", text)
    Exchanging(text) -> #("exchanging", text)
    Done(text) -> #("done", text)
    Failed(text) -> #("failed", text)
  }
  json.object([#("state", json.string(state)), #("message", json.string(text))])
}

pub fn login_json(login: Login) -> Json {
  json.object([
    #("provider", json.string(login.provider)),
    #("label", json.string(login.label)),
    #("detail", json.string(login.detail)),
    #("protocol", json.string(types.protocol_name(login.protocol))),
  ])
}

pub fn account_json(provider: String, account: Account) -> Json {
  json.object([
    #("provider", json.string(provider)),
    #("id", json.string(account.id)),
    #("label", json.string(account.label)),
    #("detail", json.string(account.detail)),
    #("selected", json.bool(account.selected)),
  ])
}

pub fn authorize_url(base: String, query: List(#(String, String))) -> String {
  base <> "?" <> uri.query_to_string(query)
}
