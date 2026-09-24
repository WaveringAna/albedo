import albedo/daemon/note
import gleam/option.{None, Some}
import gleeunit/should

pub fn wrap_round_trips_through_parse_test() {
  note.wrap("daemon restart", "body <b>")
  |> should.equal(
    "<system-note origin=\"daemon restart\">body <b></system-note>",
  )
  note.wrap("daemon restart", "body <b>")
  |> note.parse
  |> should.equal(Some(#("daemon restart", "body <b>")))
}

/// An origin cannot break out of its attribute.
pub fn wrap_keeps_the_origin_inside_its_attribute_test() {
  note.wrap("a\">b", "x")
  |> note.parse
  |> should.equal(Some(#("a')b", "x")))
}

/// A note that is already tagged keeps its own tag.
pub fn wrap_leaves_a_tagged_note_alone_test() {
  note.wrap("work", "<system-note>done</system-note>")
  |> should.equal("<system-note>done</system-note>")
}

pub fn parse_rejects_ordinary_text_test() {
  note.parse("hello") |> should.equal(None)
  note.parse("see </system-note>") |> should.equal(None)
  note.parse("<system-notes>x</system-note>") |> should.equal(None)
}
