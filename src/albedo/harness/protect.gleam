//// Runs a callback in the calling process and answers its crash as a value.
//// Extensions run in the daemon's own processes, so a plugin that raises
//// must cost its own call and nothing around it.

/// `run`'s result, with a crash reported as an error like any other failure.
pub fn guarded(run: fn() -> Result(a, String)) -> Result(a, String) {
  case attempt(run) {
    Ok(result) -> result
    Error(crash) -> Error("crashed, " <> crash)
  }
}

/// `run`'s value, or how it crashed.
@external(erlang, "albedo_protect", "run")
pub fn attempt(run: fn() -> a) -> Result(a, String)
