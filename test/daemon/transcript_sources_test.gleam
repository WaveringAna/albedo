//// Fit composition and legacy backfill faults require packed database fixtures
//// and exact source bounds that the HTTP E2E API does not expose.

import albedo/daemon/conversation
import albedo/daemon/family
import albedo/daemon/history
import albedo/daemon/image_fit
import albedo/daemon/migrations/transcript_classes
import albedo/daemon/store
import albedo/daemon/transcript
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

@external(erlang, "albedo_runtime_test_support", "temporary_database")
fn temporary_database() -> String

@external(erlang, "albedo_runtime_test_support", "cleanup")
fn cleanup(path: String) -> Nil

fn picture(hash: String) -> types.Image {
  let assert Ok(image) =
    types.stored_image("image/png", hash, 32, fn() { Error(Nil) }, 2, 3, 24)
  image
}

fn fit(source: String, replacement: types.Image) -> transcript.ImageFit {
  transcript.ImageFit("fit", source, replacement)
}

pub fn reverse_fits_preserve_chains_repeated_sources_and_reuse_test() -> Nil {
  let original = picture("A")
  let second = picture("B")
  let third = picture("C")
  let input = types.UserImage("look", [original])
  let later = image_fit.add(image_fit.replacements(), fit("A", third))
  image_fit.apply_replacements(input, later)
  |> should.equal(types.UserImage("look", [third]))
  let earlier = image_fit.add(later, fit("A", second))
  image_fit.apply_replacements(input, earlier)
  |> should.equal(types.UserImage("look", [second]))
  let chain =
    image_fit.add(
      image_fit.add(image_fit.replacements(), fit("B", third)),
      fit("A", second),
    )
  image_fit.apply_replacements(input, chain)
  |> should.equal(types.UserImage("look", [third]))
}

fn session() -> conversation.Info {
  conversation.Info(
    "session",
    "new session",
    "/tmp",
    "provider",
    "model",
    types.Responses,
    conversation.Idle,
    None,
    None,
  )
}

pub fn metadata_range_and_backfill_resume_test() -> Nil {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = conversation.create(ledger, session())
  let inputs = list.repeat(types.User("[note] daemon boundary"), 260)
  let assert Ok(_) =
    conversation.commit(ledger, "session", inputs, conversation.Idle)
  let assert Ok(_) =
    store.write(ledger, "UPDATE transcript SET row_class=NULL", [])
  // A corrupt row in the third batch is healed into a user-role note and
  // classified with it; its bytes are kept, and every batch completes.
  let assert Ok(_) =
    store.write(ledger, "UPDATE transcript SET payload=X'00' WHERE seq=260", [])
  let assert Ok(_) = transcript_classes.run(ledger)
  let assert Ok([pending]) =
    store.read(
      ledger,
      "SELECT COUNT(*) FROM transcript WHERE row_class IS NULL",
      [],
      decode.field(0, decode.int, decode.success),
    )
  pending |> should.equal(0)
  let assert Ok(quarantined) =
    store.read(ledger, "SELECT seq,payload FROM transcript_quarantine", [], {
      use seq <- decode.field(0, decode.int)
      use payload <- decode.field(1, decode.bit_array)
      decode.success(#(seq, payload))
    })
  quarantined |> should.equal([#(260, <<0>>)])
  let assert Ok(snapshot) = conversation.snapshot(ledger, "session")
  let assert Ok(stats) = conversation.source_stats(ledger, snapshot, 128)
  stats |> should.equal(conversation.SourceStats(Some(260), True, 132))
  let assert Ok(selected) =
    conversation.fold_sources(ledger, snapshot, 128, 132, [], fn(acc, row) {
      conversation.Continue([row.source.seq, ..acc])
    })
  selected |> should.equal([132, 131, 130, 129, 128])
  let assert Ok(first) =
    conversation.fold_sources(ledger, snapshot, 1, 260, 0, fn(_, row) {
      conversation.Stop(row.source.seq)
    })
  first |> should.equal(1)
  runtime.stop(host)
  cleanup(path)
}

pub fn ranged_images_equal_full_history_with_later_fits_test() -> Nil {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = family.initialise(ledger)
  let assert Ok(_) = conversation.create(ledger, session())
  let data = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAAD"
  let assert Ok(original) = types.image("image/png", data, 2, 3, 24)
  let assert Ok(second) = types.image("image/png", data <> "AAAA", 2, 3, 27)
  let assert Ok(third) = types.image("image/png", data <> "BBBB", 2, 3, 27)
  let source =
    crypto.hash(crypto.Sha256, bit_array.from_string(data))
    |> bit_array.base16_encode
    |> string.lowercase
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "session",
      [types.UserImage("before", [original])],
      conversation.Idle,
    )
  let assert Ok(_) =
    conversation.commit_fits(
      ledger,
      "session",
      [fit(source, second)],
      "provider",
    )
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "session",
      [types.UserImage("reuse", [original])],
      conversation.Idle,
    )
  let assert Ok(before_last_fit) = conversation.snapshot(ledger, "session")
  let assert Ok(_) =
    conversation.commit_fits(
      ledger,
      "session",
      [fit(source, third)],
      "provider",
    )
  let assert Ok(snapshot) = conversation.snapshot(ledger, "session")
  let assert Ok(stats) = conversation.source_stats(ledger, snapshot, 0)
  stats.uncovered_users |> should.equal(4)
  let assert Ok(full) = conversation.load_sources(ledger, "session")
  let assert Ok(range) =
    conversation.fold_sources(ledger, snapshot, 1, 3, [], fn(acc, row) {
      conversation.Continue([row, ..acc])
    })
  // Image reader functions are fresh closures, so compare content fingerprints.
  list.reverse(range)
  |> list.map(fn(row) { fingerprint(row.entry.input) })
  |> should.equal(
    list.take(full, 3) |> list.map(fn(row) { fingerprint(row.entry.input) }),
  )
  let assert Ok(reused) =
    conversation.fold_sources(ledger, snapshot, 3, 3, [], fn(acc, row) {
      conversation.Continue([fingerprint(row.entry.input), ..acc])
    })
  reused |> should.equal([fingerprint(types.UserImage("reuse", [third]))])
  let assert Ok(before) =
    conversation.fold_sources(ledger, before_last_fit, 3, 3, [], fn(acc, row) {
      conversation.Continue([fingerprint(row.entry.input), ..acc])
    })
  before |> should.equal([fingerprint(types.UserImage("reuse", [original]))])
  let assert Ok(_) = history.fork(ledger, "session", "branch", 2)
  let assert Ok(branch) = conversation.snapshot(ledger, "branch")
  let assert Ok(branch_stats) = conversation.source_stats(ledger, branch, 0)
  branch_stats.uncovered_users |> should.equal(2)
  let assert Ok(branch_rows) = conversation.load_sources(ledger, "branch")
  let assert [first, ..] = branch_rows
  fingerprint(first.entry.input)
  |> should.equal(fingerprint(types.UserImage("before", [second])))
  runtime.stop(host)
  cleanup(path)
}

@external(erlang, "albedo_compaction", "fingerprint")
fn fingerprint(value: a) -> String
