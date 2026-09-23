//// A small pure state machine, not a complete agent runtime.
//// Supply a fresh incarnation identifier whenever the owner is replaced.
//// This educational example was not compiler-verified in the research environment.

pub type RunId {
  RunId(incarnation: String, sequence: Int)
}

pub type Reason {
  UserRequested(prompt: String)
  ScheduledWake(tag: String)
}

pub type Outcome {
  Succeeded(value: String)
  Failed(reason: String)
  Stopped
}

pub type Phase {
  Idle
  Running(run_id: RunId)
  Stopping(run_id: RunId)
}

pub opaque type Model {
  Model(incarnation: String, next_sequence: Int, phase: Phase)
}

pub type Event {
  RequestRun(reason: Reason)
  RequestCancel
  WorkEnded(run_id: RunId, outcome: Outcome)
}

pub type Effect {
  StartJob(run_id: RunId, reason: Reason)
  AskJobToStop(run_id: RunId)
  ReportFinished(run_id: RunId, outcome: Outcome)
  ReportAbandoned(run_id: RunId)
  RejectBusy
}

pub fn new(incarnation: String) -> Model {
  Model(incarnation:, next_sequence: 1, phase: Idle)
}

pub fn phase(model: Model) -> Phase {
  model.phase
}

pub fn transition(model: Model, event: Event) -> #(Model, List(Effect)) {
  case event {
    RequestRun(reason) -> {
      case model.phase {
        Idle -> {
          let run_id = RunId(model.incarnation, model.next_sequence)
          #(
            Model(
              ..model,
              next_sequence: model.next_sequence + 1,
              phase: Running(run_id),
            ),
            [StartJob(run_id, reason)],
          )
        }
        Running(_) | Stopping(_) -> #(model, [RejectBusy])
      }
    }

    RequestCancel -> {
      case model.phase {
        Running(run_id) -> #(
          Model(..model, phase: Stopping(run_id)),
          [AskJobToStop(run_id)],
        )
        Idle | Stopping(_) -> #(model, [])
      }
    }

    WorkEnded(run_id, outcome) -> {
      case model.phase {
        Running(active) if active == run_id -> #(
          Model(..model, phase: Idle),
          [ReportFinished(run_id, outcome)],
        )
        Stopping(active) if active == run_id -> #(
          Model(..model, phase: Idle),
          [ReportAbandoned(run_id)],
        )
        Idle | Running(_) | Stopping(_) -> #(model, [])
      }
    }
  }
}
