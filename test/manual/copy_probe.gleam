//// Offline: what a worker spawn copies. gleam run -m manual/copy_probe
////
//// Prints the heap words a process spawned over each value carries, so a
//// value that should be shared (installed extensions) shows as nothing and
//// a per-session one (the composition) shows what it actually costs.

import albedo/harness/extension
import albedo/harness/runtime
import gleam/int
import gleam/io
import gleam/list
import harness/session_fixture

@external(erlang, "albedo_copy_test_support", "captured_words")
fn captured_words(term: a) -> Int

@external(erlang, "erlang", "element")
fn element(index: Int, term: a) -> b

fn report(name: String, term: a) -> Nil {
  io.println(
    name <> ": " <> int.to_string(captured_words(term) * 8 / 1024) <> " KiB",
  )
}

pub fn main() -> Nil {
  let workspace = "/tmp"
  let assert Ok(host) = runtime.start(":memory:")
  session_fixture.initialise(host)
  session_fixture.create(host, "probe", workspace)
  let assert Ok(session) = runtime.open_session(host, "probe", workspace)
  report("empty closure", Nil)
  report("Runtime", host)
  report("installed extensions", runtime.installed(host))
  report("Session", session)
  // Session(id, cwd, kernel, owner, composition, ...): the composition is
  // element 6 of the record tuple, after the constructor tag.
  let composition = element(6, session)
  report("  composition.extensions", extension.extensions(composition))
  // Composition(extensions, static, managed, failures): managed is element 4.
  let managed: List(extension.Prepared) = element(4, composition)
  list.each(managed, fn(prepared) {
    report("  managed " <> prepared.extension, prepared.value)
  })
  report("  instructions", runtime.instructions(session))
  report("  context", runtime.context(session))
  runtime.stop(host)
}
