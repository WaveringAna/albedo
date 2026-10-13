// The request ledger keeps a chain of hashes instead of request bodies, so a
// cache miss can be told from our own prefix drifting. The stride and tail
// positions are easy to get off by one, and an e2e scenario cannot see the
// stored column, so this pins what the chain promises: an append-only request
// agrees with its predecessor at every position they share, and a change
// anywhere earlier (head or input) moves every position from there on. The
// stream trace is counted in an atomics array its callback cannot return
// from, so its delay and byte counts are checked here too.
import albedo/daemon/requests
import albedo/daemon/stream_trace
import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should

fn inputs(count: Int) -> List(types.Input) {
  list.repeat(Nil, count)
  |> list.index_map(fn(_, index) {
    types.User("input " <> int.to_string(index))
  })
}

/// The chain as position to hash.
fn chain(head: String, inputs: List(types.Input)) -> Dict(Int, String) {
  requests.input_chain(head, [], inputs)
  |> string.split(",")
  |> list.filter_map(fn(mark) {
    case string.split(mark, ":") {
      [position, hash] ->
        int.parse(position) |> result.map(fn(position) { #(position, hash) })
      _ -> Error(Nil)
    }
  })
  |> dict.from_list
}

fn shared(a: Dict(Int, String), b: Dict(Int, String)) -> List(Int) {
  dict.keys(a)
  |> list.filter(dict.has_key(b, _))
  |> list.sort(int.compare)
}

fn agreeing(a: Dict(Int, String), b: Dict(Int, String)) -> List(Int) {
  shared(a, b)
  |> list.filter(fn(position) { dict.get(a, position) == dict.get(b, position) })
}

pub fn chain_keeps_stride_and_tail_positions_test() -> Nil {
  chain("head", inputs(40))
  |> dict.keys
  |> list.sort(int.compare)
  |> should.equal([16, 32, 37, 38, 39, 40])
  chain("head", inputs(3))
  |> dict.keys
  |> list.sort(int.compare)
  |> should.equal([1, 2, 3])
  requests.input_chain("head", [], []) |> should.equal("")
}

pub fn chain_of_an_extended_request_agrees_with_its_predecessor_test() -> Nil {
  let before = chain("head", inputs(38))
  let after = chain("head", inputs(40))
  // 16, 32, and the last positions both keep (35..38 against 37..40).
  shared(before, after) |> should.equal([16, 32, 37, 38])
  agreeing(before, after) |> should.equal([16, 32, 37, 38])
}

pub fn chain_moves_from_a_changed_input_onward_test() -> Nil {
  let original = inputs(40)
  let edited =
    list.index_map(original, fn(input, index) {
      case index {
        20 -> types.User("edited")
        _ -> input
      }
    })
  // Input 21 is the edited one: 16 precedes it and agrees, the rest do not.
  agreeing(chain("head", original), chain("head", edited))
  |> should.equal([16])
}

pub fn chain_moves_with_the_head_test() -> Nil {
  agreeing(chain("head", inputs(40)), chain("other head", inputs(40)))
  |> should.equal([])
}

pub fn a_stream_that_said_nothing_has_no_first_event_test() -> Nil {
  stream_trace.new(1000)
  |> stream_trace.streamed
  |> should.equal(stream_trace.Streamed(None, 0, 0, 0))
}

pub fn a_stream_counts_its_events_and_bytes_test() -> Nil {
  let trace = stream_trace.new(1000)
  stream_trace.observe(trace, types.Started("response"), 1400)
  stream_trace.observe(trace, types.ThinkingDelta("hmm"), 1500)
  stream_trace.observe(trace, types.ThinkingDelta("ok"), 1600)
  stream_trace.observe(trace, types.TextDelta(0, 0, "hello"), 1700)
  stream_trace.observe(trace, types.ArgumentsDelta(1, "python", "{}"), 1800)
  stream_trace.streamed(trace)
  |> should.equal(stream_trace.Streamed(Some(400), 5, 5, 7))
}
