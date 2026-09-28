//// The usage-feed driver against a fake usage CLI (ALBEDO_USAGE_CORE), a
//// local HTTP endpoint and a command that dumps its own environment. The
//// daemon has no route for quota yet, so no e2e scenario can reach this loop;
//// the bugs it catches are the host half drifting from the core's protocol:
//// the credential landing in argv instead of stdin, responses not replayed,
//// or the command environment growing beyond the allowlist.

import albedo/harness/usage_feed
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

pub type Fake

@external(erlang, "albedo_usage_test_support", "start")
fn start_fake() -> Result(Fake, Nil)

@external(erlang, "albedo_usage_test_support", "stop")
fn stop_fake(fake: Fake) -> Nil

@external(erlang, "albedo_usage_test_support", "envelope")
fn fake_envelope(fake: Fake) -> String

@external(erlang, "albedo_usage_test_support", "env_dump")
fn fake_env_dump(fake: Fake) -> String

@external(erlang, "albedo_usage_test_support", "request_line")
fn fake_request_line(fake: Fake) -> List(String)

@external(erlang, "albedo_usage_test_support", "break_binary")
fn break_binary(fake: Fake) -> Nil

@external(erlang, "albedo_usage_test_support", "mono_ms")
fn mono_ms() -> Int

@external(erlang, "albedo_usage_test_support", "trickle_pid_gone")
fn trickle_pid_gone(fake: Fake) -> Bool

fn credential() -> json.Json {
  json.object([
    #("kind", json.string("oauth")),
    #("access", json.string("tok_n0t_a_real_secret")),
  ])
}

pub fn fetch_runs_http_and_command_rounds_test() {
  let assert Ok(fake) = start_fake()
  let assert Ok(report) = usage_feed.fetch("fake", credential(), 1_234_567_890)
  // The fake core built the report from the real HTTP response body, which
  // only the loop could have delivered.
  report.account_id |> should.equal(Some("acct-1"))
  report.email |> should.equal(Some("dawn@example.com"))
  report.plan |> should.equal(Some("token"))
  report.error |> should.equal(None)
  let assert [limit] = report.limits
  limit.id |> should.equal("five_hour")
  limit.label |> should.equal("Session")
  limit.used_percent |> should.equal(Some(37.0))
  limit.window_label |> should.equal(Some("5h window"))
  limit.window_seconds |> should.equal(Some(18_000))
  limit.resets_at |> should.equal(Some(1_893_456_000_000))
  limit.scope |> should.equal(None)
  limit.status |> should.equal("ok")
  // The HTTP request went through albedo's HTTP client to the local endpoint.
  fake_request_line(fake) |> should.equal(["GET /usage HTTP/1.1"])
  // The envelope crossed on stdin, never argv: both logged rounds carry the
  // provider, the credential and nowMs, and the second replays the responses.
  let envelope = fake_envelope(fake)
  envelope |> string.contains("\"provider\":\"fake\"") |> should.be_true
  envelope |> string.contains("tok_n0t_a_real_secret") |> should.be_true
  envelope |> string.contains("\"nowMs\":1234567890") |> should.be_true
  envelope |> string.contains("\"responses\":[]") |> should.be_true
  envelope |> string.contains("\"status\":200") |> should.be_true
  // The command ran with only the allowed environment: no canary, and the
  // resolver override itself never reached the child.
  let dumped = fake_env_dump(fake)
  dumped |> string.contains("ALBEDO_USAGE_TEST_CANARY") |> should.be_false
  dumped |> string.contains("ALBEDO_USAGE_CORE") |> should.be_false
  dumped |> string.contains("PATH=") |> should.be_true
  dumped |> string.contains("HOME=") |> should.be_true
  stop_fake(fake)
}

pub fn a_provider_error_is_data_not_a_driver_failure_test() {
  let assert Ok(fake) = start_fake()
  let assert Ok(report) = usage_feed.fetch("broken", credential(), 0)
  report.error |> should.equal(Some("the provider is unreachable"))
  report.limits |> should.equal([])
  report.account_id |> should.equal(None)
  stop_fake(fake)
}

pub fn a_feed_that_never_reports_is_a_driver_failure_test() {
  let assert Ok(fake) = start_fake()
  let assert Error(message) = usage_feed.fetch("endless", credential(), 0)
  message |> string.contains("did not finish in 6 rounds") |> should.be_true
  stop_fake(fake)
}

pub fn a_missing_binary_is_a_driver_failure_test() {
  let assert Ok(fake) = start_fake()
  break_binary(fake)
  let assert Error(message) = usage_feed.fetch("fake", credential(), 0)
  message |> string.contains("usage is not built") |> should.be_true
  stop_fake(fake)
}

pub fn a_command_off_path_answers_126_test() {
  let assert Ok(fake) = start_fake()
  // The fake core asks for a command that does not exist; the feed routes
  // around a non-zero status, so the report still arrives.
  let assert Ok(report) = usage_feed.fetch("missing-command", credential(), 0)
  report.error |> should.equal(Some("command answered 126"))
  stop_fake(fake)
}

pub fn a_trickling_command_hits_its_deadline_and_is_killed_test() {
  let assert Ok(fake) = start_fake()
  // The trickle command always has output but never exits: an idle timeout
  // would let it run forever, so only the deadline across chunks ends it.
  let started = mono_ms()
  let assert Ok(report) = usage_feed.fetch("trickle", credential(), 0)
  let elapsed = mono_ms() - started
  report.error |> should.equal(Some("command answered 126"))
  // The request's 1s timeoutMs is honoured, not the 15s default.
  should.be_true(elapsed < 4000)
  // And the child was killed, not orphaned with closed pipes.
  trickle_pid_gone(fake) |> should.be_true
  stop_fake(fake)
}
