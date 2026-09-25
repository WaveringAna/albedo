import albedo/daemon/conversation
import albedo/daemon/history
import albedo/daemon/store
import albedo/daemon/transcript
import albedo/daemon/usage
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import sqlight

@external(erlang, "albedo_runtime_test_support", "temporary_database")
fn temporary_database() -> String

@external(erlang, "albedo_runtime_test_support", "cleanup")
fn cleanup(path: String) -> Nil

fn info(id: String) -> conversation.Info {
  conversation.Info(
    id,
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

fn response_item(source: String) -> types.ReplayItem {
  let assert Ok(item) =
    json.parse(source, types.replay_decoder(types.Responses))
  item
}

fn sequences(ledger: store.Store, session: String) -> List(Int) {
  let assert Ok(rows) =
    store.query(ledger, fn(db) {
      sqlight.query(
        "SELECT seq FROM transcript WHERE session=? ORDER BY seq",
        db,
        [sqlight.text(session)],
        decode.field(0, decode.int, decode.success),
      )
    })
  rows
}

pub fn source_references_survive_append_and_are_scoped_to_forks_test() {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = conversation.create(ledger, info("source"))
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "source",
      [types.User("first"), types.Assistant("reply")],
      conversation.Idle,
    )
  let assert Ok([first, second]) = conversation.load_sources(ledger, "source")
  let assert transcript.SourceRef("source", first_seq) = first.source
  let assert transcript.SourceRef("source", second_seq) = second.source
  { first_seq < second_seq } |> should.be_true
  conversation.source(ledger, first.source)
  |> should.equal(Ok(Some(first.entry)))

  let assert Ok(_) =
    conversation.commit(
      ledger,
      "source",
      [types.User("later")],
      conversation.Idle,
    )
  let assert Ok([kept, _, _]) = conversation.load_sources(ledger, "source")
  kept.source |> should.equal(first.source)

  let assert Ok(_) = history.fork(ledger, "source", "branch", second_seq)
  let assert Ok([branch_first, branch_second]) =
    conversation.load_sources(ledger, "branch")
  branch_first.entry |> should.equal(first.entry)
  branch_second.entry |> should.equal(second.entry)
  let assert transcript.SourceRef("branch", branch_seq) = branch_first.source
  { branch_seq != first_seq } |> should.be_true
  conversation.source(ledger, transcript.SourceRef("branch", first_seq))
  |> should.equal(Ok(None))
  runtime.stop(host)
  cleanup(path)
}

pub fn sourced_entries_stay_ordered_across_read_pages_test() {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = conversation.create(ledger, info("paged"))
  let inputs =
    int.range(from: 1, to: 261, with: [], run: fn(acc, i) {
      [types.User(int.to_string(i)), ..acc]
    })
    |> list.reverse
  let assert Ok(_) =
    conversation.commit(ledger, "paged", inputs, conversation.Idle)
  let assert Ok(sources) = conversation.load_sources(ledger, "paged")
  let assert Ok(entries) = conversation.load_entries(ledger, "paged")
  list.length(sources) |> should.equal(260)
  list.map(sources, fn(row) { row.entry }) |> should.equal(entries)
  let assert [first, ..] = sources
  let assert Ok(last) = list.last(sources)
  first.entry.input |> should.equal(types.User("1"))
  last.entry.input |> should.equal(types.User("260"))
  runtime.stop(host)
  cleanup(path)
}

pub fn page_is_bounded_chronological_and_redacts_provider_bodies_test() {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = conversation.create(ledger, info("source"))
  let reasoning =
    response_item(
      "{\"type\":\"reasoning\",\"id\":\"reasoning-1\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"bounded private rationale\"}]}",
    )
  let call =
    response_item(
      "{\"type\":\"function_call\",\"call_id\":\"call-1\",\"name\":\"python\",\"arguments\":\"{\\\"opaque\\\":\\\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\\\"}\",\"status\":\"completed\"}",
    )
  let assert Ok(_) =
    conversation.commit_from(
      ledger,
      "source",
      [
        types.User("first prompt"),
        types.Replay(reasoning),
        types.Replay(call),
        types.ToolOutput("call-1", "tool output", []),
      ],
      conversation.Idle,
      Some("provider"),
    )
  let assert [user_seq, reasoning_seq, call_seq, _] =
    sequences(ledger, "source")

  let assert Ok(history.Page(first, Some(cursor), True)) =
    history.page(ledger, "source", 0, 2)
  first
  |> should.equal([
    history.Item(user_seq, history.User, "first prompt", first_timestamp(first)),
    history.Item(
      reasoning_seq,
      history.Assistant,
      "[reasoning] bounded private rationale",
      first_timestamp(first),
    ),
  ])
  cursor |> should.equal(reasoning_seq)

  let assert Ok(history.Page(second, Some(_), False)) =
    history.page(ledger, "source", cursor, 1000)
  let assert [tool_call, tool_result] = second
  #(tool_call.id, tool_call.kind, tool_call.preview)
  |> should.equal(#(call_seq, history.Tool, "call python"))
  tool_result.kind |> should.equal(history.Tool)
  tool_result.preview |> should.equal("tool output")
  runtime.stop(host)
  cleanup(path)
}

fn first_timestamp(items: List(history.Item)) {
  let assert [first, ..] = items
  first.timestamp
}

pub fn fork_copies_only_prefix_provenance_extensions_and_completes_tools_test() {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = conversation.create(ledger, info("source"))
  let call =
    response_item(
      "{\"type\":\"function_call\",\"call_id\":\"call-1\",\"name\":\"python\",\"arguments\":\"{}\",\"status\":\"completed\"}",
    )
  let assert Ok(_) =
    conversation.commit_from(
      ledger,
      "source",
      [types.User("branch me"), types.Replay(call)],
      conversation.Tool,
      Some("provider-a"),
    )
  let assert Ok(_) =
    conversation.commit_from(
      ledger,
      "source",
      [
        types.ToolOutput("call-1", "actual later result", []),
        types.Assistant("later answer"),
      ],
      conversation.Idle,
      Some("provider-a"),
    )
  let assert Ok(_) =
    conversation.record_usage(
      ledger,
      "source",
      usage.Metadata("model", 42, None),
    )
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      sqlight.query(
        "INSERT INTO session_extensions(session,name,enabled) VALUES('source','python',0)",
        db,
        [],
        decode.dynamic,
      )
    })
  let assert [_, checkpoint, _, _] = sequences(ledger, "source")
  let assert Ok(branch) = history.fork(ledger, "source", "branch", checkpoint)
  #(
    branch.id,
    branch.title,
    conversation.stage_name(branch.stage),
    branch.last_assistant_at,
  )
  |> should.equal(#("branch", "branch me", "idle", None))

  let assert Ok(source) = conversation.load_entries(ledger, "source")
  let assert Ok(forked) = conversation.load_entries(ledger, "branch")
  list.length(source) |> should.equal(4)
  let assert [user, replay, completed] = forked
  user.input |> should.equal(types.User("branch me"))
  user.provider |> should.equal(Some("provider-a"))
  replay.input |> should.equal(types.Replay(call))
  replay.provider |> should.equal(Some("provider-a"))
  completed.input
  |> should.equal(
    types.ToolOutput("call-1", "not executed after branch checkpoint", []),
  )
  conversation.load_usage(ledger, "branch") |> should.equal(Ok(None))
  let assert Ok([#("python", 0)]) =
    store.query(ledger, fn(db) {
      sqlight.query(
        "SELECT name,enabled FROM session_extensions WHERE session='branch'",
        db,
        [],
        {
          use name <- decode.field(0, decode.string)
          use enabled <- decode.field(1, decode.int)
          decode.success(#(name, enabled))
        },
      )
    })

  runtime.stop(host)
  let assert Ok(restarted) = runtime.start(path)
  let ledger = runtime.ledger(restarted)
  let assert Ok(_) = conversation.initialise(ledger)
  conversation.load_entries(ledger, "branch") |> should.equal(Ok(forked))
  conversation.load_entries(ledger, "source") |> should.equal(Ok(source))
  runtime.stop(restarted)
  cleanup(path)
}

pub fn incompatible_or_missing_checkpoints_leave_no_branch_test() {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = conversation.create(ledger, info("source"))
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "source",
      [types.ToolOutput("orphan", "bad history", [])],
      conversation.Idle,
    )
  let assert [checkpoint] = sequences(ledger, "source")
  history.fork(ledger, "source", "orphan-branch", checkpoint)
  |> should.equal(Error("checkpoint contains a tool result without its call"))
  history.fork(ledger, "source", "missing-branch", checkpoint + 100)
  |> should.equal(Error("checkpoint not found"))
  let assert Ok([only]) = conversation.list(ledger)
  only.id |> should.equal("source")
  runtime.stop(host)
  cleanup(path)
}

pub fn recent_keeps_newest_conversation_and_counts_every_row_test() {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = conversation.create(ledger, info("source"))
  let reasoning =
    response_item(
      "{\"type\":\"reasoning\",\"id\":\"reasoning-1\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"hidden\"}]}",
    )
  let call =
    response_item(
      "{\"type\":\"function_call\",\"call_id\":\"call-1\",\"name\":\"python\",\"arguments\":\"{}\",\"status\":\"completed\"}",
    )
  let assert Ok(_) =
    conversation.commit_from(
      ledger,
      "source",
      [
        types.User("first\nprompt"),
        types.Replay(reasoning),
        types.Replay(call),
        types.ToolOutput("call-1", "tool output", []),
        types.Assistant("all done"),
      ],
      conversation.Idle,
      Some("provider"),
    )

  let assert Ok(history.Recent(items, 5)) = history.recent(ledger, "source", 2)
  items
  |> list.map(fn(item) { #(item.kind, item.preview) })
  |> should.equal([#(history.Tool, "python"), #(history.Assistant, "all done")])

  let assert Ok(history.Recent(all, _)) = history.recent(ledger, "source", 10)
  all
  |> list.map(fn(item) { item.preview })
  |> should.equal(["first prompt", "python", "all done"])

  let assert Ok(history.Recent([], 0)) = history.recent(ledger, "missing", 10)
  runtime.stop(host)
  cleanup(path)
}
