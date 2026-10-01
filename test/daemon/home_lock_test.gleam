/// Concurrent ownership of one home conflicts with the one-daemon E2E harness.
import albedo/daemon/server
import gleam/erlang/process
import gleeunit/should

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil

pub fn second_daemon_cannot_claim_a_held_home_test() -> Nil {
  let #(root, _, home) = fixture()
  let claimed = process.new_subject()
  // A subject only delivers to the process that created it, so the owner makes
  // its own release subject and hands it back.
  process.spawn(fn() {
    let release = process.new_subject()
    process.send(claimed, #(server.claim_home(home), release))
    process.receive_forever(release)
  })
  let assert Ok(#(first, release)) = process.receive(claimed, 5000)
  first |> should.equal(Ok(Nil))

  server.claim_home(home) |> should.equal(Error(Nil))

  // The connection closes when the owner's resources are freed, which can land
  // just after its exit is observable, so a fresh claimant retries briefly.
  process.send(release, Nil)
  claim_eventually(home, 50) |> should.equal(Ok(Nil))

  cleanup(root)
}

fn claim_eventually(home: String, attempts: Int) -> Result(Nil, Nil) {
  let reply = process.new_subject()
  process.spawn(fn() { process.send(reply, server.claim_home(home)) })
  case process.receive(reply, 5000) {
    Ok(Ok(Nil)) -> Ok(Nil)
    _ if attempts > 1 -> {
      process.sleep(20)
      claim_eventually(home, attempts - 1)
    }
    _ -> Error(Nil)
  }
}
