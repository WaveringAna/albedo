# Shared runtime helpers

## clocks

`albedo/clock.gleam` owns Gleam clock access. Use `system_ms` or
`system_seconds` for durable timestamps and expiry, `monotonic_ms` for elapsed
time and deadlines, and `os_system_ms` only when OS-clock semantics are required.
Store slow-query timing uses `clock.monotonic_ms`. Reuse these functions instead
of adding local clock externals or wrappers. Erlang native time units are
VM-dependent; request an explicit unit rather than dividing native ticks.

## Unicode scalar limits

`albedo/text_scalars.gleam` owns scalar counting and slicing. Its `length`,
`take`, `drop`, and `tail` scan UTF-8 without creating a whole codepoint list;
retained slices are copied so they release the source binary. Scalars are not
graphemes. Use these helpers for bounded previews and names, including from
Erlang through `'albedo@text_scalars':take(Text, Limit)`. The kernel job summary
retains at most 4096 scalars; truncating it must not allocate a list for the
entire command.

## native boundaries

Keep process state, ports, monitors, ETF, and native binary matching in their
Erlang owners. Reuse Gleam owners for pure validation and text projection.
A new Erlang shim should supply a native capability, not duplicate an existing
Gleam helper. Keep typed values through internal projections and encode JSON at
the wire boundary; see [command state projections](commands.md#contributing-commands).
