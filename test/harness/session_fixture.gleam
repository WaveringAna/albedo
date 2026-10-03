//// Native session facts needed by a component runtime's composition capture.

import albedo/daemon/conversation
import albedo/daemon/family
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/option.{None}

pub fn initialise(host: runtime.Runtime) -> Nil {
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = family.initialise(ledger)
  Nil
}

pub fn create(host: runtime.Runtime, id: String, workspace: String) -> Nil {
  let ledger = runtime.ledger(host)
  let assert Ok(_) =
    conversation.create(
      ledger,
      conversation.Info(
        id,
        "component session",
        workspace,
        "provider",
        "model",
        types.Responses,
        conversation.Idle,
        None,
        None,
      ),
    )
  Nil
}
