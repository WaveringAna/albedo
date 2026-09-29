//// Copy into the receiving project's test directory and use its test runner.
//// These tests were written and source-reviewed, but not executed here.

import session_core as core

pub fn user_and_wake_reasons_remain_distinct_test() {
  let model = core.new("owner-a")
  let #(_, user_effects) =
    core.transition(model, core.RequestRun(core.UserRequested("hello")))
  let assert [core.StartJob(_, core.UserRequested("hello"))] = user_effects

  let #(_, wake_effects) =
    core.transition(model, core.RequestRun(core.ScheduledWake("daily")))
  let assert [core.StartJob(_, core.ScheduledWake("daily"))] = wake_effects
  Nil
}

pub fn running_request_is_rejected_without_changing_state_test() {
  let #(running, _) =
    core.transition(
      core.new("owner-a"),
      core.RequestRun(core.UserRequested("first")),
    )
  let #(same, effects) =
    core.transition(running, core.RequestRun(core.UserRequested("second")))
  let assert True = same == running
  let assert [core.RejectBusy] = effects
  Nil
}

pub fn cancellation_waits_for_worker_end_test() {
  let #(running, effects) =
    core.transition(
      core.new("owner-a"),
      core.RequestRun(core.UserRequested("first")),
    )
  let assert [core.StartJob(id, _)] = effects

  let #(stopping, effects) = core.transition(running, core.RequestCancel)
  let assert [core.AskJobToStop(stop_id)] = effects
  let assert True = stop_id == id
  let assert True = core.phase(stopping) == core.Stopping(id)

  let #(same, effects) =
    core.transition(stopping, core.RequestRun(core.ScheduledWake("daily")))
  let assert True = same == stopping
  let assert [core.RejectBusy] = effects

  let #(idle, effects) =
    core.transition(stopping, core.WorkEnded(id, core.Stopped))
  let assert True = core.phase(idle) == core.Idle
  let assert [core.ReportAbandoned(ended_id)] = effects
  let assert True = ended_id == id
  Nil
}

pub fn repeated_cancellation_does_not_send_another_stop_request_test() {
  let #(running, _) =
    core.transition(
      core.new("owner-a"),
      core.RequestRun(core.ScheduledWake("daily")),
    )
  let #(stopping, _) = core.transition(running, core.RequestCancel)
  let #(same, effects) = core.transition(stopping, core.RequestCancel)
  let assert True = same == stopping
  let assert [] = effects
  Nil
}

pub fn duplicate_completion_has_no_effect_test() {
  let #(running, effects) =
    core.transition(
      core.new("owner-a"),
      core.RequestRun(core.UserRequested("hello")),
    )
  let assert [core.StartJob(id, _)] = effects
  let event = core.WorkEnded(id, core.Succeeded("done"))
  let #(idle, _) = core.transition(running, event)
  let #(same, effects) = core.transition(idle, event)
  let assert True = same == idle
  let assert [] = effects
  Nil
}

pub fn old_run_completion_does_not_finish_the_new_run_test() {
  let #(running, effects) =
    core.transition(
      core.new("owner-a"),
      core.RequestRun(core.UserRequested("first")),
    )
  let assert [core.StartJob(old_id, _)] = effects
  let #(idle, _) =
    core.transition(running, core.WorkEnded(old_id, core.Succeeded("done")))
  let #(new_run, _) =
    core.transition(idle, core.RequestRun(core.UserRequested("second")))
  let #(same, effects) =
    core.transition(new_run, core.WorkEnded(old_id, core.Succeeded("late")))
  let assert True = same == new_run
  let assert [] = effects
  Nil
}

pub fn previous_owner_completion_does_not_match_reused_sequence_test() {
  let #(_, old_effects) =
    core.transition(
      core.new("owner-a"),
      core.RequestRun(core.UserRequested("old")),
    )
  let assert [core.StartJob(old_id, _)] = old_effects
  let #(new_run, _) =
    core.transition(
      core.new("owner-b"),
      core.RequestRun(core.UserRequested("new")),
    )
  let #(same, effects) =
    core.transition(new_run, core.WorkEnded(old_id, core.Succeeded("late")))
  let assert True = same == new_run
  let assert [] = effects
  Nil
}

pub fn successful_work_racing_with_cancel_is_abandoned_not_rolled_back_test() {
  let #(running, effects) =
    core.transition(
      core.new("owner-a"),
      core.RequestRun(core.UserRequested("first")),
    )
  let assert [core.StartJob(id, _)] = effects
  let #(stopping, _) = core.transition(running, core.RequestCancel)
  let #(idle, effects) =
    core.transition(stopping, core.WorkEnded(id, core.Succeeded("committed")))
  let assert True = core.phase(idle) == core.Idle
  let assert [core.ReportAbandoned(ended_id)] = effects
  let assert True = ended_id == id
  Nil
}

pub fn failed_work_reports_its_outcome_and_releases_the_run_test() {
  let #(running, effects) =
    core.transition(
      core.new("owner-a"),
      core.RequestRun(core.ScheduledWake("daily")),
    )
  let assert [core.StartJob(id, _)] = effects
  let #(idle, effects) =
    core.transition(running, core.WorkEnded(id, core.Failed("unavailable")))
  let assert True = core.phase(idle) == core.Idle
  let assert [core.ReportFinished(ended_id, core.Failed("unavailable"))] =
    effects
  let assert True = ended_id == id
  Nil
}
