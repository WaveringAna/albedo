//// Where tool results sit in a transcript: right after the calls they answer.

import albedo/daemon/message_content
import albedo/daemon/transcript
import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/order

/// Scan state: each row's sort key and index (newest first), the block of
/// consecutive provider items being read and whether only its results have
/// followed it, the block each call belongs to, and each block's last row.
type Scan {
  Scan(
    keys: List(#(Int, Int)),
    block: Int,
    in_block: Bool,
    in_run: Bool,
    owners: Dict(String, Int),
    run_end: Dict(Int, Int),
  )
}

/// `items` in chronological order, with every tool result that other rows
/// separated from its call moved to the end of that call's results. History
/// already in order comes back unchanged.
pub fn settle(items: List(a), input: fn(a) -> types.Input) -> List(a) {
  let scan =
    list.index_fold(
      items,
      Scan([], -1, False, False, dict.new(), dict.new()),
      fn(scan, item, index) { step(scan, input(item), index) },
    )
  case list.all(scan.keys, fn(key) { key.0 == 2 * key.1 }) {
    True -> items
    False ->
      list.zip(list.reverse(scan.keys), items)
      |> list.sort(fn(a, b) {
        let #(#(key_a, index_a), _) = a
        let #(#(key_b, index_b), _) = b
        int.compare(key_a, key_b)
        |> order.break_tie(int.compare(index_a, index_b))
      })
      |> list.map(fn(pair) { pair.1 })
  }
}

/// The call ids the tool results in `inputs` answer.
pub fn answered(inputs: List(types.Input)) -> List(String) {
  list.filter_map(inputs, fn(input) {
    case input {
      types.ToolOutput(id, _, _) -> Ok(id)
      _ -> Error(Nil)
    }
  })
}

/// Settled `entries`, each slot keeping its saved source, and the moves as
/// (from, to) seqs that make the saved transcript match.
pub fn settle_entries(
  entries: List(transcript.Entry),
) -> #(List(transcript.Entry), List(#(Int, Int))) {
  let settled = settle(entries, fn(entry) { entry.input })
  let pairs = list.zip(entries, settled)
  let placed =
    list.map(pairs, fn(pair) {
      transcript.Entry(..pair.1, source: { pair.0 }.source)
    })
  let moves =
    list.filter_map(pairs, fn(pair) {
      case { pair.1 }.source, { pair.0 }.source {
        Some(from), Some(to) if from.seq != to.seq -> Ok(#(from.seq, to.seq))
        _, _ -> Error(Nil)
      }
    })
  #(placed, moves)
}

/// A row keeps key `2 * index`; a late result takes the odd key just after
/// the last row of its call's block and results, so the sort moves it there.
fn step(scan: Scan, input: types.Input, index: Int) -> Scan {
  let kept = [#(2 * index, index), ..scan.keys]
  case input {
    types.Replay(_) -> {
      let block = case scan.in_block {
        True -> scan.block
        False -> index
      }
      let owners =
        list.fold(message_content.calls(input), scan.owners, fn(owners, call) {
          dict.insert(owners, call.id, block)
        })
      Scan(
        keys: kept,
        block:,
        in_block: True,
        in_run: True,
        owners:,
        run_end: dict.insert(scan.run_end, block, index),
      )
    }
    types.ToolOutput(id, _, _) ->
      case dict.get(scan.owners, id) {
        Ok(block) if block == scan.block && scan.in_run ->
          Scan(
            ..scan,
            keys: kept,
            in_block: False,
            run_end: dict.insert(scan.run_end, block, index),
          )
        Ok(block) ->
          case dict.get(scan.run_end, block) {
            Ok(end) -> Scan(..scan, keys: [#(2 * end + 1, index), ..scan.keys])
            Error(_) -> Scan(..scan, keys: kept)
          }
        Error(_) -> Scan(..scan, keys: kept, in_block: False, in_run: False)
      }
    _ -> Scan(..scan, keys: kept, in_block: False, in_run: False)
  }
}
