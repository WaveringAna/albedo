import gleeunit

pub fn main() -> Nil {
  isolate_home()
  gleeunit.main()
}

@external(erlang, "albedo_test_home", "isolate")
fn isolate_home() -> Nil
