//// Browser OAuth sign-ins that the daemon runs for every client. An extension
//// describes its provider; `albedo_oauth` owns the callback listener, the
//// race with a pasted code, and locked creds.json storage.

import albedo/openai_api/types
import gleam/dynamic.{type Dynamic}
import gleam/json.{type Json}
import gleam/option.{type Option}
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

/// Durable identified login operations. The owner stores only a keyed digest
/// of the submitted intent and safe flow metadata, never submitted values.
@external(erlang, "albedo_oauth", "start_identified")
pub fn start_identified(
  home: String,
  id: String,
  provider: String,
  login: Option(Login),
  intent: String,
) -> Result(#(Bool, String), #(Int, String, String))

@external(erlang, "albedo_oauth", "get_identified")
pub fn get_identified(
  home: String,
  id: String,
  logins: List(Login),
) -> Result(String, #(Int, String, String))

@external(erlang, "albedo_oauth", "input_identified")
pub fn input_identified(
  home: String,
  id: String,
  match: String,
  text: String,
  logins: List(Login),
) -> Result(String, #(Int, String, String))

@external(erlang, "albedo_oauth", "cancel_identified")
pub fn cancel_identified(
  home: String,
  id: String,
  logins: List(Login),
) -> Result(String, #(Int, String, String))

@external(erlang, "albedo_oauth", "auth_snapshot")
pub fn auth_snapshot(
  home: String,
  logins: List(Login),
) -> Result(String, #(Int, String, String))

@external(erlang, "albedo_oauth", "remove_account")
pub fn remove_account(
  home: String,
  logins: List(Login),
  id: String,
) -> Result(Nil, #(Int, String, String))

@external(erlang, "albedo_oauth", "accounts")
pub fn accounts(home: String, login: Login) -> List(Account)

pub fn authorize_url(base: String, query: List(#(String, String))) -> String {
  base <> "?" <> uri.query_to_string(query)
}
