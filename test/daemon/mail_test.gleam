import albedo/daemon/conversation
import albedo/daemon/family
import albedo/daemon/mail
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

@external(erlang, "albedo_runtime_test_support", "temporary_database")
fn temporary_database() -> String

@external(erlang, "albedo_runtime_test_support", "cleanup")
fn cleanup(path: String) -> Nil

fn session(id: String, title: String) -> conversation.Info {
  conversation.Info(
    id,
    title,
    "/tmp",
    "provider",
    "model",
    types.Responses,
    conversation.Idle,
    None,
    None,
  )
}

/// A root "lead" with children "coder" and "critic", and "tests" under coder,
/// plus an unrelated root "radio".
fn with_family(run: fn(runtime.Runtime) -> Nil) -> Nil {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let db = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(db)
  let assert Ok(_) = mail.initialise(db)
  let assert Ok(_) = family.initialise(db)
  list.each(
    [
      #("s_lead", "lead"),
      #("s_coder", "coder"),
      #("s_critic", "critic"),
      #("s_tests", "tests"),
      #("s_radio", "radio"),
    ],
    fn(pair) {
      let assert Ok(_) = conversation.create(db, session(pair.0, pair.1))
      Nil
    },
  )
  let assert Ok(_) = family.link(db, "s_coder", "s_lead", "coder")
  let assert Ok(_) = family.link(db, "s_critic", "s_lead", "critic")
  let assert Ok(tests) = family.link(db, "s_tests", "s_coder", "tests")
  tests.depth |> should.equal(2)
  run(host)
  runtime.stop(host)
  cleanup(path)
}

pub fn names_resolve_inside_the_family_only_test() {
  use host <- with_family
  let db = runtime.ledger(host)
  let assert Ok(family.Address("s_coder", "coder")) =
    family.resolve(db, "s_lead", "coder")
  let assert Ok(family.Address("s_critic", "critic")) =
    family.resolve(db, "s_coder", "critic")
  let assert Ok(family.Address("s_lead", "lead")) =
    family.resolve(db, "s_coder", "parent")
  let assert Ok(family.Address("s_coder", "coder")) =
    family.resolve(db, "s_tests", "coder")
  // A grandchild is not family by name, and neither is an unrelated root...
  let assert Error(message) = family.resolve(db, "s_lead", "tests")
  string.contains(message, "by id") |> should.be_true
  let assert Error(_) = family.resolve(db, "s_lead", "radio")
  // ...but anyone is reachable by id.
  let assert Ok(family.Address("s_tests", "tests")) =
    family.resolve(db, "s_lead", "s_tests")
  let assert Ok(family.Address("s_radio", "radio")) =
    family.resolve(db, "s_tests", "s_radio")
  let assert Error(_) = family.resolve(db, "s_lead", "parent")
  Nil
}

pub fn family_limits_depth_names_and_width_test() {
  use host <- with_family
  let db = runtime.ledger(host)
  let assert Ok(_) = conversation.create(db, session("s_deep", "deep"))
  let assert Ok(member) = family.link(db, "s_deep", "s_tests", "deep")
  member.depth |> should.equal(3)
  let assert Ok(_) = conversation.create(db, session("s_deeper", "deeper"))
  let assert Error(message) = family.link(db, "s_deeper", "s_deep", "deeper")
  string.contains(message, "by id") |> should.be_true
  let assert Error(_) = family.link(db, "s_deeper", "s_lead", "coder")
  let assert Error(_) = family.link(db, "s_deeper", "s_lead", "parent")
  let assert Error(_) = family.link(db, "s_deeper", "s_lead", "Has Spaces")
  Nil
}

pub fn a_letter_is_delivered_once_test() {
  use host <- with_family
  let db = runtime.ledger(host)
  let assert Ok(letter) =
    mail.post(db, "m1", "s_coder", Some("s_lead"), "lead", mail.Task, "go")
  mail.undelivered(db, "m1") |> should.be_true
  let assert Ok([pending]) = mail.pending(db, 10)
  pending |> should.equal(letter)
  let assert Ok(_) =
    conversation.commit_letters(
      db,
      "s_coder",
      [types.User(mail.text(letter))],
      conversation.Model,
      None,
      ["m1"],
    )
  mail.undelivered(db, "m1") |> should.be_false
  let assert Ok([]) = mail.pending(db, 10)
  // A retry of the same letter cannot commit a second copy.
  let assert Error(_) =
    conversation.commit_letters(
      db,
      "s_coder",
      [types.User(mail.text(letter))],
      conversation.Model,
      None,
      ["m1"],
    )
  let assert Ok(entries) = conversation.load_entries(db, "s_coder")
  list.length(entries) |> should.equal(1)
}

pub fn mail_is_not_a_person_test() {
  let letter =
    mail.Letter("m1", "s_coder", Some("s_lead"), "lead", mail.Message, "hi", 0)
  mail.is_mail(mail.text(letter)) |> should.be_true
  conversation.latest_user([types.User("fix it"), types.User(mail.text(letter))])
  |> should.equal(Some("fix it"))
}

pub fn letters_are_bounded_and_never_to_oneself_test() {
  use host <- with_family
  let db = runtime.ledger(host)
  let assert Error(_) =
    mail.post(db, "m1", "s_lead", Some("s_lead"), "lead", mail.Message, "hi")
  let assert Error(_) =
    mail.post(db, "m2", "s_lead", None, "x", mail.Message, "  ")
  let assert Error(message) =
    mail.post(db, "m3", "s_nobody", None, "x", mail.Message, "hi")
  string.contains(message, "s_nobody") |> should.be_true
}

pub fn a_child_owes_its_parent_until_it_writes_back_test() {
  use host <- with_family
  let db = runtime.ledger(host)
  // Nothing asked yet: nothing owed.
  mail.owes_reply(db, "s_coder", "s_lead") |> should.equal(Ok(False))
  let assert Ok(_) =
    mail.post(db, "m1", "s_coder", Some("s_lead"), "lead", mail.Task, "go")
  let assert Ok(_) =
    conversation.commit_letters(
      db,
      "s_coder",
      [types.User("go")],
      conversation.Model,
      None,
      ["m1"],
    )
  mail.owes_reply(db, "s_coder", "s_lead") |> should.equal(Ok(True))
  let assert Ok(receipt) = mail.send(db, "s_coder", "parent", "done")
  receipt.recipient |> should.equal("s_lead")
  receipt.name |> should.equal("lead")
  // No actor is running in this test, so the letter waits for the dispatcher.
  receipt.status |> should.equal("pending")
  mail.owes_reply(db, "s_coder", "s_lead") |> should.equal(Ok(False))
}
