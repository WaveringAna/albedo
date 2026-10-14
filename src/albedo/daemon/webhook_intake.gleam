//// The port the webhook intake listener bound, published once at boot so the
//// webhooks extension can show senders a url that reaches it.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/result

pub fn publish(port: Int) -> Nil {
  put(key(), port)
  Nil
}

/// After the intake stops, webhooks show no url until the daemon restarts.
pub fn clear() -> Nil {
  erase(key())
  Nil
}

/// The bound port; Error in a process with no intake listener, such as a
/// unit test.
pub fn port() -> Result(Int, Nil) {
  get(key(), dynamic.nil())
  |> decode.run(decode.int)
  |> result.replace_error(Nil)
}

/// The url a sender posts `hook`'s deliveries to on `port`.
pub fn delivery_url(port: Int, hook: String) -> String {
  "http://127.0.0.1:" <> int.to_string(port) <> delivery_path(hook)
}

/// `delivery_url` on the bound port, or the bare path where none is bound.
pub fn address(hook: String) -> String {
  case port() {
    Ok(port) -> delivery_url(port, hook)
    Error(Nil) -> delivery_path(hook)
  }
}

pub fn delivery_path(hook: String) -> String {
  "/extensions/webhooks/hooks/" <> hook <> "/deliveries"
}

fn key() -> Atom {
  atom.create("albedo_webhook_intake_port")
}

@external(erlang, "persistent_term", "put")
fn put(key: Atom, value: Int) -> Atom

@external(erlang, "persistent_term", "erase")
fn erase(key: Atom) -> Bool

@external(erlang, "persistent_term", "get")
fn get(key: Atom, default: Dynamic) -> Dynamic
