//// Wall timestamps and elapsed-time deadlines use distinct clocks.

type Unit {
  Millisecond
  Second
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: Unit) -> Int

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: Unit) -> Int

@external(erlang, "os", "system_time")
fn os_system_time(unit: Unit) -> Int

pub fn system_ms() -> Int {
  system_time(Millisecond)
}

pub fn system_seconds() -> Int {
  system_time(Second)
}

pub fn monotonic_ms() -> Int {
  monotonic_time(Millisecond)
}

/// Codex cache freshness retains its OS-clock source.
pub fn os_system_ms() -> Int {
  os_system_time(Millisecond)
}
