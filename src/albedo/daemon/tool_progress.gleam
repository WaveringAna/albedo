//// Bounded live projection of a streaming tool's JSON arguments.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Snapshot {
  Snapshot(
    call_id: String,
    tool_call_id: Option(String),
    name: String,
    phase: String,
    code: Option(#(Int, String)),
  )
}

pub type Update {
  Update(
    projection: Projection,
    snapshot: Option(Snapshot),
    invalidates_progress: Bool,
  )
}

pub opaque type Projection {
  Projection(
    attempt: Option(Int),
    step: Option(Int),
    enabled: Bool,
    calls: Dict(Int, Call),
  )
}

type Call {
  Call(
    progress_id: String,
    tool_call_id: Option(String),
    name: String,
    scanner: Scanner,
    phase: String,
    dirty: Bool,
  )
}

type Scanner {
  Scanner(
    depth: Int,
    last_significant: Int,
    in_string: Bool,
    string_role: StringRole,
    key: String,
    pending_code_key: Bool,
    code_escape: Escape,
    high_surrogate: Option(Int),
    code_total: Int,
    code_tail: Queue,
    disabled: Bool,
  )
}

type Queue {
  Queue(front: List(UtfCodepoint), back: List(UtfCodepoint), size: Int)
}

type StringRole {
  IgnoreString
  KeyString
  CodeString
}

type Escape {
  Plain
  Backslash
  Unicode(digits: String)
}

pub fn new() -> Projection {
  Projection(None, None, True, dict.new())
}

pub fn clear(projection: Projection) -> Projection {
  Projection(projection.attempt, projection.step, True, dict.new())
}

pub fn enabled(projection: Projection) -> Bool {
  projection.enabled
}

pub fn has_calls(projection: Projection) -> Bool {
  dict.size(projection.calls) > 0
}

pub fn has_dirty(projection: Projection) -> Bool {
  projection.calls
  |> dict.to_list
  |> list.any(fn(entry) { entry.1.dirty && entry.1.name != "" })
}

pub fn reset_attempt(attempt: Int) -> Projection {
  Projection(Some(attempt), None, True, dict.new())
}

pub fn update(
  projection: Projection,
  generation generation: String,
  run_id run_id: String,
  step step: Int,
  attempt attempt: Int,
  output_index output_index: Int,
  incoming_name incoming_name: String,
  fragment fragment: String,
) -> Update {
  let scope_changed =
    projection.attempt != Some(attempt) || projection.step != Some(step)
  let projection = case scope_changed {
    True -> Projection(Some(attempt), Some(step), True, dict.new())
    False -> projection
  }
  case projection.enabled {
    False -> Update(projection, None, scope_changed)
    True ->
      case dict.get(projection.calls, output_index) {
        Ok(call) ->
          project_fragment(
            projection,
            output_index,
            call,
            incoming_name,
            fragment,
            scope_changed,
          )
        Error(_) ->
          case dict.size(projection.calls) >= 32 {
            True ->
              Update(
                Projection(Some(attempt), Some(step), False, dict.new()),
                None,
                True,
              )
            False ->
              project_fragment(
                projection,
                output_index,
                Call(
                  progress_id(
                    generation: generation,
                    run_id: run_id,
                    step: step,
                    attempt: attempt,
                    output_index: output_index,
                  ),
                  None,
                  "",
                  scanner(),
                  "generating",
                  False,
                ),
                incoming_name,
                fragment,
                scope_changed,
              )
          }
      }
  }
}

fn project_fragment(
  projection: Projection,
  output_index: Int,
  call: Call,
  incoming_name: String,
  fragment: String,
  scope_changed: Bool,
) -> Update {
  let name = bounded(incoming_name, 100)
  let name = case name {
    "" -> call.name
    value -> value
  }
  let scanner = scan(call.scanner, fragment)
  let appeared = call.name == "" && name != ""
  let changed =
    name != call.name
    || scanner.code_total != call.scanner.code_total
    || scanner.disabled != call.scanner.disabled
  let call =
    Call(..call, name:, scanner:, dirty: !appeared && { call.dirty || changed })
  let calls = dict.insert(projection.calls, output_index, call)
  let projection = Projection(projection.attempt, projection.step, True, calls)
  let snapshot = case appeared {
    True -> Some(snapshot(call))
    False -> None
  }
  Update(projection, snapshot, scope_changed)
}

pub fn running(
  projection: Projection,
  generation generation: String,
  run_id run_id: String,
  step step: Int,
  attempt attempt: Int,
  output_index output_index: Int,
  tool_call_id tool_call_id: String,
  name name: String,
) -> Update {
  let scope_changed =
    projection.attempt != Some(attempt) || projection.step != Some(step)
  let projection = case scope_changed {
    True -> Projection(Some(attempt), Some(step), True, dict.new())
    False -> projection
  }
  let call = case dict.get(projection.calls, output_index) {
    Ok(call) -> call
    Error(_) ->
      Call(
        progress_id(
          generation: generation,
          run_id: run_id,
          step: step,
          attempt: attempt,
          output_index: output_index,
        ),
        None,
        bounded(name, 100),
        scanner(),
        "generating",
        False,
      )
  }
  let call =
    Call(
      ..call,
      tool_call_id: case string.byte_size(tool_call_id) <= 200 {
        True -> Some(tool_call_id)
        False -> None
      },
      name: bounded(name, 100),
      phase: "running",
      dirty: False,
    )
  let calls = case
    dict.has_key(projection.calls, output_index)
    || dict.size(projection.calls) < 32
  {
    True -> dict.insert(projection.calls, output_index, call)
    False -> projection.calls
  }
  let projection =
    Projection(Some(attempt), Some(step), projection.enabled, calls)
  let snapshot = case call.name {
    "" -> None
    _ -> Some(snapshot(call))
  }
  Update(projection, snapshot, scope_changed)
}

pub fn flush_dirty(projection: Projection) -> #(Projection, List(Snapshot)) {
  let #(calls, snapshots) =
    projection.calls
    |> dict.to_list
    |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
    |> list.fold(#(dict.new(), []), fn(acc, entry) {
      let #(calls, snapshots) = acc
      let call = entry.1
      case call.dirty && call.name != "" {
        True -> #(dict.insert(calls, entry.0, Call(..call, dirty: False)), [
          snapshot(call),
          ..snapshots
        ])
        False -> #(dict.insert(calls, entry.0, call), snapshots)
      }
    })
  #(
    Projection(projection.attempt, projection.step, projection.enabled, calls),
    list.reverse(snapshots),
  )
}

pub fn finish_call(projection: Projection, progress_id: String) -> Projection {
  let kept =
    projection.calls
    |> dict.to_list
    |> list.filter(fn(entry) { entry.1.progress_id != progress_id })
  Projection(
    projection.attempt,
    projection.step,
    projection.enabled,
    dict.from_list(kept),
  )
}

pub fn snapshots(projection: Projection) -> List(Snapshot) {
  projection.calls
  |> dict.to_list
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  |> list.filter_map(fn(entry) {
    case entry.1.name {
      "" -> Error(Nil)
      _ -> Ok(snapshot(entry.1))
    }
  })
}

pub fn progress_id(
  generation generation: String,
  run_id run_id: String,
  step step: Int,
  attempt attempt: Int,
  output_index output_index: Int,
) -> String {
  generation
  <> ":"
  <> run_id
  <> ":"
  <> int.to_string(step)
  <> ":"
  <> int.to_string(attempt)
  <> ":"
  <> int.to_string(output_index)
}

fn snapshot(call: Call) -> Snapshot {
  let tail = queue_values(call.scanner.code_tail)
  let code = case call.scanner.disabled, call.name, tail {
    True, _, _ -> None
    False, "python", [] -> None
    False, "python", _ ->
      Some(#(
        call.scanner.code_total - call.scanner.code_tail.size,
        string.from_utf_codepoints(tail),
      ))
    False, _, _ -> None
  }
  Snapshot(call.progress_id, call.tool_call_id, call.name, call.phase, code)
}

fn scanner() -> Scanner {
  Scanner(
    depth: 0,
    last_significant: 0,
    in_string: False,
    string_role: IgnoreString,
    key: "",
    pending_code_key: False,
    code_escape: Plain,
    high_surrogate: None,
    code_total: 0,
    code_tail: Queue([], [], 0),
    disabled: False,
  )
}

fn scan(scanner: Scanner, fragment: String) -> Scanner {
  scan_codepoints(scanner, string.to_utf_codepoints(fragment))
}

fn scan_codepoints(
  scanner: Scanner,
  codepoints: List(UtfCodepoint),
) -> Scanner {
  case scanner.disabled {
    True -> scanner
    False ->
      case
        scanner.in_string,
        scanner.string_role,
        scanner.code_escape,
        scanner.high_surrogate
      {
        True, CodeString, Plain, None -> {
          // Ordinary source characters need one scanner update per fragment;
          // escapes and JSON structure still pass through the state machine.
          let #(plain, remaining) =
            list.split_while(codepoints, fn(cp) {
              let value = string.utf_codepoint_to_int(cp)
              value != 34 && value != 92
            })
          let scanner =
            Scanner(
              ..scanner,
              code_total: scanner.code_total + list.length(plain),
              code_tail: list.fold(plain, scanner.code_tail, queue_push),
            )
          case remaining {
            [] -> scanner
            [cp, ..rest] -> scan_codepoints(scan_codepoint(scanner, cp), rest)
          }
        }
        _, _, _, _ ->
          case codepoints {
            [] -> scanner
            [cp, ..rest] -> scan_codepoints(scan_codepoint(scanner, cp), rest)
          }
      }
  }
}

fn scan_codepoint(scanner: Scanner, character: UtfCodepoint) -> Scanner {
  case scanner.disabled {
    True -> scanner
    False ->
      case scanner.in_string {
        True -> scan_string(scanner, character)
        False -> scan_outside(scanner, character)
      }
  }
}

fn scan_outside(scanner: Scanner, character: UtfCodepoint) -> Scanner {
  let cp = string.utf_codepoint_to_int(character)
  case cp {
    34 -> {
      let role = case scanner.depth, scanner.last_significant {
        1, 123 | 1, 44 -> KeyString
        1, 58 if scanner.pending_code_key -> CodeString
        _, _ -> IgnoreString
      }
      Scanner(..scanner, in_string: True, string_role: role, key: "")
    }
    123 | 91 -> {
      let depth = scanner.depth + 1
      case depth > 64 {
        True -> disable_scanner(scanner)
        False ->
          Scanner(
            ..scanner,
            depth:,
            last_significant: cp,
            pending_code_key: False,
          )
      }
    }
    125 | 93 ->
      Scanner(
        ..scanner,
        depth: int.max(0, scanner.depth - 1),
        last_significant: cp,
      )
    58 if scanner.depth == 1 -> Scanner(..scanner, last_significant: cp)
    44 if scanner.depth == 1 ->
      Scanner(..scanner, last_significant: cp, pending_code_key: False)
    _ -> scanner
  }
}

fn scan_string(scanner: Scanner, character: UtfCodepoint) -> Scanner {
  case scanner.string_role {
    KeyString -> scan_key(scanner, character)
    CodeString -> scan_code(scanner, character)
    IgnoreString -> scan_ignored_string(scanner, character)
  }
}

fn scan_key(scanner: Scanner, character: UtfCodepoint) -> Scanner {
  case string.utf_codepoint_to_int(character) {
    // Escaped keys are outside this preview parser's subset. Stop rather than
    // mistaking an escaped quote for the end of a key and scanning its value.
    92 -> disable_scanner(scanner)
    34 ->
      Scanner(
        ..scanner,
        in_string: False,
        string_role: IgnoreString,
        pending_code_key: scanner.key == "code",
        last_significant: 0,
      )
    _ -> {
      let key = case string.byte_size(scanner.key) < 16 {
        True -> scanner.key <> string.from_utf_codepoints([character])
        False -> scanner.key
      }
      Scanner(..scanner, key: key)
    }
  }
}

fn scan_ignored_string(scanner: Scanner, character: UtfCodepoint) -> Scanner {
  case string.utf_codepoint_to_int(character), scanner.code_escape {
    34, Plain -> Scanner(..scanner, in_string: False, last_significant: 0)
    92, Plain -> Scanner(..scanner, code_escape: Backslash)
    _, Backslash -> Scanner(..scanner, code_escape: Plain)
    _, _ -> scanner
  }
}

fn scan_code(scanner: Scanner, character: UtfCodepoint) -> Scanner {
  case string.utf_codepoint_to_int(character), scanner.code_escape {
    34, Plain if scanner.high_surrogate == None ->
      Scanner(
        ..scanner,
        in_string: False,
        string_role: IgnoreString,
        pending_code_key: False,
        last_significant: 0,
        code_escape: Plain,
      )
    92, Plain -> Scanner(..scanner, code_escape: Backslash)
    _, Plain if scanner.high_surrogate != None -> disable_scanner(scanner)
    _, Backslash ->
      decode_escape(scanner, string.from_utf_codepoints([character]))
    _, Plain -> add_code(scanner, character)
    _, Unicode(_) ->
      unicode_escape(scanner, string.from_utf_codepoints([character]))
  }
}

fn decode_escape(scanner: Scanner, character: String) -> Scanner {
  let decoded = case character {
    "n" -> Some("\n")
    "r" -> Some("\r")
    "t" -> Some("\t")
    "b" -> Some("\u{0008}")
    "f" -> Some("\u{000c}")
    "\\" -> Some("\\")
    "\"" -> Some("\"")
    "/" -> Some("/")
    _ -> None
  }
  case character {
    "u" -> Scanner(..scanner, code_escape: Unicode(""))
    _ ->
      case decoded {
        Some(text) -> {
          let assert [cp] = string.to_utf_codepoints(text)
          add_code(Scanner(..scanner, code_escape: Plain), cp)
        }
        None -> disable_scanner(scanner)
      }
  }
}

fn unicode_escape(scanner: Scanner, character: String) -> Scanner {
  let digits = case scanner.code_escape {
    Unicode(digits) -> digits
    _ -> ""
  }
  let digits = digits <> character
  case string.length(digits) == 4 {
    False -> Scanner(..scanner, code_escape: Unicode(digits))
    True ->
      case int.base_parse(digits, 16) {
        Error(_) -> disable_scanner(scanner)
        Ok(value) -> add_unicode_codepoint(scanner, value)
      }
  }
}

fn add_unicode_codepoint(scanner: Scanner, value: Int) -> Scanner {
  case scanner.high_surrogate, value {
    None, high if high >= 55_296 && high <= 56_319 ->
      Scanner(..scanner, code_escape: Plain, high_surrogate: Some(high))
    Some(high), low if low >= 56_320 && low <= 57_343 -> {
      let codepoint = 65_536 + { high - 55_296 } * 1024 + low - 56_320
      case string.utf_codepoint(codepoint) {
        Ok(cp) ->
          add_code(
            Scanner(..scanner, code_escape: Plain, high_surrogate: None),
            cp,
          )
        Error(_) -> disable_scanner(scanner)
      }
    }
    None, normal ->
      case string.utf_codepoint(normal) {
        Ok(cp) -> add_code(Scanner(..scanner, code_escape: Plain), cp)
        Error(_) -> disable_scanner(scanner)
      }
    _, _ -> disable_scanner(scanner)
  }
}

fn add_code(scanner: Scanner, character: UtfCodepoint) -> Scanner {
  Scanner(
    ..scanner,
    code_total: scanner.code_total + 1,
    code_tail: queue_push(scanner.code_tail, character),
  )
}

fn disable_scanner(scanner: Scanner) -> Scanner {
  Scanner(..scanner, code_tail: Queue([], [], 0), disabled: True)
}

fn queue_push(queue: Queue, value: UtfCodepoint) -> Queue {
  let queue = Queue(..queue, back: [value, ..queue.back], size: queue.size + 1)
  case queue.size > 512 {
    False -> queue
    True -> queue_drop_oldest(queue)
  }
}

fn queue_drop_oldest(queue: Queue) -> Queue {
  case queue.front {
    [_, ..front] -> Queue(..queue, front:, size: queue.size - 1)
    [] ->
      case list.reverse(queue.back) {
        [_, ..front] -> Queue(front:, back: [], size: queue.size - 1)
        [] -> queue
      }
  }
}

fn queue_values(queue: Queue) -> List(UtfCodepoint) {
  list.append(queue.front, list.reverse(queue.back))
}

fn bounded(value: String, maximum_bytes: Int) -> String {
  bounded_codepoints(string.to_utf_codepoints(value), maximum_bytes, [], 0)
}

fn bounded_codepoints(
  remaining: List(UtfCodepoint),
  maximum_bytes: Int,
  kept: List(UtfCodepoint),
  bytes: Int,
) -> String {
  case remaining {
    [] -> kept |> list.reverse |> string.from_utf_codepoints
    [codepoint, ..rest] -> {
      let size = utf8_size(string.utf_codepoint_to_int(codepoint))
      case bytes + size <= maximum_bytes {
        True ->
          bounded_codepoints(
            rest,
            maximum_bytes,
            [codepoint, ..kept],
            bytes + size,
          )
        False -> kept |> list.reverse |> string.from_utf_codepoints
      }
    }
  }
}

fn utf8_size(value: Int) -> Int {
  case value <= 127 {
    True -> 1
    False ->
      case value <= 2047 {
        True -> 2
        False ->
          case value <= 65_535 {
            True -> 3
            False -> 4
          }
      }
  }
}
