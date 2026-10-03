//// Delete an observed family with bounded results and actual stop outcomes.

import albedo/daemon/bus
import albedo/daemon/conversation
import albedo/daemon/family
import albedo/daemon/mail
import albedo/daemon/session
import albedo/daemon/store
import albedo/harness/runtime
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sqlight

pub type Report {
  Report(
    deleted_count: Int,
    remaining_count: Int,
    deleted_ids: List(String),
    remaining: List(#(String, String)),
    truncated: Bool,
  )
}

type Deletion {
  Deletion(
    host: runtime.Runtime,
    home: String,
    claim: family.DeletionClaim,
    deadline: Int,
    on_deleted: fn(String) -> Nil,
  )
}

type Progress {
  Progress(deleted_ids: List(String), failures: Dict(String, String))
}

@external(erlang, "albedo_session", "now_ms")
fn now_ms() -> Int

@external(erlang, "albedo_context_snapshot", "page")
fn reason_prefix(text: String, index: Int, scalars: Int) -> String

pub fn execute(
  host: runtime.Runtime,
  home: String,
  request: family.DeletionRequest,
  on_deleted: fn(String) -> Nil,
) -> Result(Report, String) {
  let ledger = runtime.ledger(host)
  let token = mail.new_id()
  let admission = case session.live(request.session) {
    Some(worker) -> session.claim_deletion(worker, request, token)
    None -> family.claim_deletion(ledger, request, token, now_ms() + 5000)
  }
  use claim <- result.try(case admission {
    Ok(claim) -> Ok(claim)
    Error(error) -> {
      use _ <- result.try(family.release_deletion(
        ledger,
        family.DeletionClaim(token, request.session, 0),
      ))
      Error(error)
    }
  })
  let deletion = Deletion(host, home, claim, now_ms() + 30_000, on_deleted)
  let outcome = walk(deletion, None, Progress([], dict.new()))
  let released = family.release_deletion(ledger, claim)
  use report <- result.try(outcome)
  use _ <- result.try(released)
  bus.invalidate(["/sessions"], report.deleted_ids, report.truncated)
  Ok(report)
}

fn walk(
  deletion: Deletion,
  after_member: Option(family.DeletionMember),
  progress: Progress,
) -> Result(Report, String) {
  let ledger = runtime.ledger(deletion.host)
  use members <- result.try(family.deletion_members(
    ledger,
    deletion.claim,
    after_member,
  ))
  case members, now_ms() >= deletion.deadline {
    [], _ | _, True -> report(ledger, deletion.claim, progress)
    _, False -> {
      let progress =
        list.fold(members, progress, fn(progress, member) {
          let remaining_ms = deletion.deadline - now_ms()
          let removed = case remaining_ms <= 0 {
            True -> Error("deletion deadline reached")
            False -> remove(deletion, member.id, remaining_ms)
          }
          case removed {
            Ok(_) -> {
              deletion.on_deleted(member.id)
              Progress(
                case list.length(progress.deleted_ids) < 200 {
                  True -> [member.id, ..progress.deleted_ids]
                  False -> progress.deleted_ids
                },
                progress.failures,
              )
            }
            Error(error) ->
              Progress(
                ..progress,
                failures: case dict.size(progress.failures) < 200 {
                  True ->
                    dict.insert(
                      progress.failures,
                      member.id,
                      reason_prefix(error, 0, 256),
                    )
                  False -> progress.failures
                },
              )
          }
        })
      walk(deletion, list.last(members) |> option.from_result, progress)
    }
  }
}

fn remove(
  deletion: Deletion,
  id: String,
  remaining_ms: Int,
) -> Result(Nil, String) {
  use _ <- result.try(case session.live(id) {
    Some(worker) -> session.close_for_deletion(worker, remaining_ms)
    None -> runtime.delete_session(deletion.host, id)
  })
  use _ <- result.try(conversation.delete_claimed(
    runtime.ledger(deletion.host),
    id,
    deletion.claim,
    runtime.cleaners(deletion.host),
  ))
  session.discard_state(deletion.home, id)
  Ok(Nil)
}

fn report(
  ledger: store.Store,
  claim: family.DeletionClaim,
  progress: Progress,
) -> Result(Report, String) {
  use remaining_count <- result.try(
    store.query(ledger, fn(db) {
      store.one(
        db,
        "SELECT COUNT(*) FROM sessions WHERE deletion_id=?",
        [sqlight.text(claim.token)],
        decode.field(0, decode.int, decode.success),
        "deletion report unavailable",
      )
    }),
  )
  use remaining <- result.try(family.deletion_members(ledger, claim, None))
  let deleted_count = claim.captured_count - remaining_count
  Ok(Report(
    deleted_count,
    remaining_count,
    list.reverse(progress.deleted_ids),
    list.map(remaining, fn(member) {
      #(
        member.id,
        dict.get(progress.failures, member.id)
          |> result.unwrap("deletion did not finish before its deadline"),
      )
    }),
    deleted_count > list.length(progress.deleted_ids)
      || remaining_count > list.length(remaining),
  ))
}
