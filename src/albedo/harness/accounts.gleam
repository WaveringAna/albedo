//// Pure pool ordering. The native owner captures time and session affinity.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

pub type Entry(account) {
  Entry(value: account, identity: String, selected: Bool, limited_until: Int)
}

pub fn order(
  entries: List(Entry(account)),
  session: String,
  sticky: Option(String),
  now: Int,
) -> List(account) {
  let #(limited, open) =
    list.partition(entries, fn(entry) { entry.limited_until > now })
  let #(selected, rest) =
    list.partition(spread(open, session, sticky), fn(entry) { entry.selected })
  let limited =
    list.sort(limited, fn(first, second) {
      int.compare(first.limited_until, second.limited_until)
    })
  list.append(selected, list.append(rest, limited))
  |> list.map(fn(entry) { entry.value })
}

fn spread(
  entries: List(Entry(account)),
  session: String,
  sticky: Option(String),
) -> List(Entry(account)) {
  case entries, sticky {
    [], _ -> []
    _, Some(identity) -> {
      let #(hit, others) =
        list.partition(entries, fn(entry) { entry.identity == identity })
      list.append(hit, others)
    }
    _, None -> {
      let start =
        fingerprint(<<session:utf8>>, 0x811C9DC5) % list.length(entries)
      let #(head, tail) = list.split(entries, start)
      list.append(tail, head)
    }
  }
}

fn fingerprint(bytes: BitArray, hash: Int) -> Int {
  case bytes {
    <<byte, rest:bytes>> ->
      fingerprint(
        rest,
        int.bitwise_and(
          int.bitwise_exclusive_or(hash, byte) * 16_777_619,
          0xFFFFFFFF,
        ),
      )
    _ -> hash
  }
}
