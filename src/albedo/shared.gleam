//// A read-mostly value every process reads without copying it.
////
//// `publish` stores the value in a persistent term, so a `read` is a pointer
//// to it and a process that captures or sends what it read copies nothing.
//// Reading is cheap; publishing a new value and releasing one scan every
//// process, so publish once per lifetime, like the installed extensions.
//// Reading a released handle is a lifecycle bug, like calling a stopped
//// actor, and panics.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/reference.{type Reference}

/// The handle is also the persistent term key, so each value has its own and
/// the type parameter says what a read returns.
pub opaque type Shared(a) {
  Shared(key: Reference)
}

pub fn publish(value: a) -> Shared(a) {
  let shared = Shared(reference.new())
  let _ = put(shared, Ok(value))
  shared
}

pub fn read(shared: Shared(a)) -> a {
  case get(shared, Error(Nil)) {
    Ok(value) -> value
    Error(Nil) -> panic as "shared value was released"
  }
}

pub fn release(shared: Shared(a)) -> Nil {
  let _ = erase(shared)
  Nil
}

@external(erlang, "persistent_term", "put")
fn put(key: Shared(a), value: Result(a, Nil)) -> Dynamic

@external(erlang, "persistent_term", "get")
fn get(key: Shared(a), default: Result(a, Nil)) -> Result(a, Nil)

@external(erlang, "persistent_term", "erase")
fn erase(key: Shared(a)) -> Bool
