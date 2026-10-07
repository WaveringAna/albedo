//// Deterministic effect gates for helper lifetime tests; never shipped.

import albedo/daemon/storage_cli
import gleam/erlang/process

@external(erlang, "albedo_storage_test_support", "signal")
fn signal(operation: String, path: String) -> Nil

pub fn main() -> Nil {
  let assert [operation, home, path] = storage_cli.arguments()
  storage_cli.maintain(
    home,
    fn(file) {
      case operation {
        "delete" -> gate(operation, path)
        _ -> Nil
      }
      storage_cli.remove(file)
    },
    fn(file) {
      case operation {
        "vacuum" -> gate(operation, path)
        _ -> Nil
      }
      storage_cli.vacuum(file)
    },
  )
  |> storage_cli.finish
}

fn gate(operation: String, path: String) -> Nil {
  signal(operation, path)
  process.sleep_forever()
}
