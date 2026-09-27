pub fn main() -> Nil {
  isolate_home()
  run()
}

@external(erlang, "albedo_test_home", "isolate")
fn isolate_home() -> Nil

@external(erlang, "albedo_test_runner", "main")
fn run() -> Nil
