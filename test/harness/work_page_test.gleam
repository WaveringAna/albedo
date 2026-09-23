//// The /work page: a document the CLI renders, and user changes that are
//// also queued as notes for the agent.

import albedo/harness/command
import albedo/harness/extensions/work/command as work_command
import albedo/harness/extensions/work/ledger as work
import gleam/dict
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

fn setup() {
  let assert Ok(store) = work.start(":memory:")
  let notes = process.new_subject()
  let context =
    command.Context(fn(op) {
      process.send(notes, op)
      Ok(json.null())
    })
  #(store, notes, work_command.command(store), context)
}

fn run(
  page: command.Command,
  context,
  caller,
  action: String,
  details: String,
) {
  let args = case action {
    "" -> dict.new()
    _ -> dict.from_list([#("action", action), #("details", details)])
  }
  let assert Ok(command.Data(value)) = page.run(context, caller, args)
  json.to_string(value)
}

pub fn listing_is_a_page_document_ordered_by_status_test() {
  let #(store, _, page, context) = setup()
  let assert Ok(_) = work.create(store, "write docs", "", None)
  let assert Ok(active) = work.create(store, "fix bug", "", None)
  let assert Ok(_) =
    work.update(store, work.Item(..active, status: work.Active))
  page.page |> should.be_true
  let document = run(page, context, command.UserCall, "", "")
  string.contains(document, "\"title\":\"work\"") |> should.be_true
  string.contains(document, "\"summary\":\"1 active · 1 open\"")
  |> should.be_true
  // Active work sorts first, in both the page and its sidebar glance.
  let assert Ok(#(_, rows)) = string.split_once(document, "\"rows\":")
  let assert True =
    string.split_once(rows, "fix bug")
    |> fn(split) {
      case split {
        Ok(#(before, _)) -> !string.contains(before, "write docs")
        Error(_) -> False
      }
    }
  string.contains(document, "\"glance\":{") |> should.be_true
}

pub fn user_changes_update_the_ledger_and_queue_a_note_test() {
  let #(store, notes, page, context) = setup()
  let added = run(page, context, command.UserCall, "add", "buy milk")
  string.contains(added, "added #1 · buy milk") |> should.be_true
  let assert Ok(command.Note("work", "added #1 · buy milk", text)) =
    process.receive(notes, 0)
  string.contains(text, "The user added work item #1") |> should.be_true

  run(page, context, command.UserCall, "status", "1 done")
  let assert Ok(item) = work.get(store, 1)
  item.status |> should.equal(work.Done)
  let assert Ok(command.Note(_, "marked done #1 · buy milk", _)) =
    process.receive(notes, 0)

  run(page, context, command.UserCall, "edit", "#1 buy oat milk")
  let assert Ok(item) = work.get(store, 1)
  item.title |> should.equal("buy oat milk")
  let assert Ok(_) = process.receive(notes, 0)

  run(page, context, command.UserCall, "remove", "1")
  work.get(store, 1) |> should.equal(Error(work.NotFound))
  let assert Ok(command.Note(_, "removed #1 · buy oat milk", _)) =
    process.receive(notes, 0)
}

pub fn failed_changes_and_model_calls_queue_nothing_test() {
  let #(store, notes, page, context) = setup()
  let assert Ok(parent) = work.create(store, "parent", "", None)
  let assert Ok(_) = work.create(store, "child", "", Some(parent.id))
  page.run(
    context,
    command.UserCall,
    dict.from_list([#("action", "remove"), #("details", "1")]),
  )
  |> should.equal(Error("remove its sub-items first"))
  page.run(
    context,
    command.ModelCall,
    dict.from_list([#("action", "add"), #("details", "sneaky")]),
  )
  |> should.equal(Error("only a user changes the ledger through /work"))
  page.run(
    context,
    command.UserCall,
    dict.from_list([#("action", "status"), #("details", "1 finished")]),
  )
  |> should.equal(Error(
    "unknown work status finished; use open, active, blocked, done, or cancelled",
  ))
  process.receive(notes, 0) |> should.equal(Error(Nil))
}

pub fn delete_is_revision_checked_test() {
  let #(store, _, _, _) = setup()
  let assert Ok(item) = work.create(store, "stale", "", None)
  let assert Ok(_) = work.update(store, work.Item(..item, title: "fresh"))
  work.delete(store, item.id, item.revision)
  |> should.equal(Error(work.Conflict))
  let assert Ok(current) = work.get(store, item.id)
  let assert Ok(_) = work.delete(store, current.id, current.revision)
}
