//// Trace actual BEAM reads and decodes: E2E cannot observe discarded matches,
//// sparse keyset query counts, or how many source and node rows were decoded.

import albedo/daemon/conversation
import albedo/daemon/store
import albedo/harness/extensions/lcm/graph
import albedo/harness/runtime
import albedo/harness/search
import albedo/harness/tool
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleeunit/should
import sqlight

pub type Counts {
  Counts(pages: Int, decoded: Int, sources: Int, nodes: Int, kept: Int)
}

@external(erlang, "albedo_retrieval_test_support", "measure")
fn measure(owner: process.Pid, run: fn() -> a) -> #(a, Counts)

@external(erlang, "albedo_conversation", "pack")
fn pack(input: types.Input) -> BitArray

fn fixture() -> #(runtime.Runtime, store.Store) {
  let assert Ok(host) = runtime.start(":memory:")
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = graph.initialise(ledger)
  let _ =
    list.each(["wanted", "other"], fn(session) {
      let assert Ok(_) =
        conversation.create(
          ledger,
          conversation.Info(
            session,
            "fixture",
            "/tmp",
            "fixture",
            "fixture",
            types.Responses,
            conversation.Idle,
            None,
            None,
          ),
        )
    })
  #(host, ledger)
}

fn insert(ledger: store.Store, session: String, seq: Int, text: String) -> Nil {
  let assert Ok(_) =
    store.write(
      ledger,
      "INSERT INTO transcript(seq,session,payload,row_class) VALUES(?,?,?,'user')",
      [
        sqlight.int(seq),
        sqlight.text(session),
        sqlight.blob(pack(types.User(text))),
      ],
    )
  Nil
}

pub fn sparse_scoped_search_advances_by_rows_not_global_sequence_gaps_test() -> Nil {
  let #(host, ledger) = fixture()
  insert(ledger, "other", 1, "needle")
  insert(ledger, "wanted", 200_000, "needle older")
  insert(ledger, "other", 400_000, "needle")
  insert(ledger, "wanted", 600_000, "needle newer")
  let #(result, counts) =
    measure(store.owner(ledger), fn() {
      search.page(ledger, "wanted", "needle", 0, 700_000, 0, 20)
    })
  let assert Ok(page) = result
  page.count |> should.equal(2)
  list.map(page.matches, fn(match) { match.seq })
  |> should.equal([200_000, 600_000])
  counts.pages |> should.equal(2)
  counts.decoded |> should.equal(2)
  let #(result, counts) =
    measure(store.owner(ledger), fn() {
      search.fold(
        ledger,
        search.Beyond("other", "/tmp"),
        "needle",
        [],
        fn(_, _) { True },
        fn(found, match) { [match.seq, ..found] },
      )
    })
  result |> should.equal(Ok([200_000, 600_000]))
  counts.pages |> should.equal(2)
  counts.decoded |> should.equal(2)
  runtime.stop(host)
}

pub fn exact_search_count_keeps_only_requested_twenty_matches_test() -> Nil {
  let #(host, ledger) = fixture()
  let _ =
    list.each(
      list.index_map(list.repeat(Nil, 2200), fn(_, index) { index + 1 }),
      fn(seq) { insert(ledger, "wanted", seq, "needle") },
    )
  let #(result, counts) =
    measure(store.owner(ledger), fn() {
      search.page(ledger, "wanted", "needle", 0, 3000, 30, 20)
    })
  let assert Ok(page) = result
  page.count |> should.equal(2200)
  list.length(page.matches) |> should.equal(20)
  counts.decoded |> should.equal(2200)
  counts.pages |> should.equal(3)
  counts.kept |> should.equal(20)
  runtime.stop(host)
}

pub fn node_listing_decodes_only_page_and_source_read_stops_after_page_test() -> Nil {
  let #(host, ledger) = fixture()
  let _ =
    list.each(
      list.index_map(list.repeat(Nil, 300), fn(_, index) { index + 1 }),
      fn(seq) { insert(ledger, "wanted", seq, "body") },
    )
  let assert Ok(_) =
    graph.save_leaves(
      ledger,
      "wanted",
      list.map(
        list.index_map(list.repeat(Nil, 45), fn(_, index) { index + 1 }),
        fn(seq) { graph.Leaf(seq, seq, "summary") },
      ),
    )
  // Positive control: the tracer observes the old full node-read operation.
  let #(all, control) =
    measure(store.owner(ledger), fn() {
      store.query(ledger, fn(db) {
        store.rows(
          db,
          "SELECT id,depth,first_seq,last_seq,summary FROM lcm_compaction_node WHERE session=? ORDER BY id",
          [sqlight.text("wanted")],
          decode.field(0, decode.int, decode.success),
        )
      })
    })
  let assert Ok(all) = all
  list.length(all) |> should.equal(45)
  control.nodes |> should.equal(45)
  let #(page, counts) =
    measure(store.owner(ledger), fn() {
      graph.list_page(ledger, "wanted", 7, 5)
    })
  let assert Ok(page) = page
  page.total |> should.equal(45)
  counts.nodes |> should.equal(7)
  let assert Ok(snapshot) = conversation.snapshot(ledger, "wanted")
  let #(page, counts) =
    measure(store.owner(ledger), fn() {
      tool.source_page(ledger, snapshot, 200, 300, "row", 0, 1)
    })
  let assert Ok(#("[", 1, True)) = page
  counts.sources |> should.equal(101)
  let #(page, counts) =
    measure(store.owner(ledger), fn() {
      tool.source_page(ledger, snapshot, 1, 300, "row", 0, 1)
    })
  let assert Ok(#("[", 1, True)) = page
  counts.sources |> should.equal(128)
  runtime.stop(host)
}

pub fn excluded_global_rows_advance_cross_session_cursor_without_decoding_test() -> Nil {
  let #(host, ledger) = fixture()
  insert(ledger, "wanted", 1, "needle")
  let _ =
    list.each(
      list.index_map(list.repeat(Nil, 2200), fn(_, index) { index + 2 }),
      fn(seq) { insert(ledger, "other", seq, "needle") },
    )
  let #(result, counts) =
    measure(store.owner(ledger), fn() {
      search.fold(
        ledger,
        search.Beyond("other", "/tmp"),
        "needle",
        [],
        fn(_, _) { True },
        fn(found, match) { [match.seq, ..found] },
      )
    })
  result |> should.equal(Ok([1]))
  counts.pages |> should.equal(3)
  counts.decoded |> should.equal(1)
  runtime.stop(host)
}
