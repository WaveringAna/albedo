//// The wildcard retry algorithm must agree with exhaustive small-pattern
//// matching, including overlapping wildcard retries. HTTP E2E cannot cover
//// this combinatorial space or reliably catch exponential work regressions.

import albedo/harness/cache_ttl
import gleam/list
import gleam/string
import gleeunit/should

fn words(alphabet: List(String), length: Int) -> List(String) {
  case length {
    0 -> [""]
    _ -> {
      let shorter = words(alphabet, length - 1)
      list.append(
        [""],
        list.flat_map(alphabet, fn(head) {
          list.map(shorter, fn(tail) { head <> tail })
        }),
      )
    }
  }
}

// An intentionally exhaustive oracle for bounded inputs; the production
// matcher must not explore both branches recursively on long inputs.
fn exhaustive(pattern: List(String), value: List(String)) -> Bool {
  case pattern, value {
    [], [] -> True
    ["*", ..rest], _ ->
      exhaustive(rest, value)
      || case value {
        [_, ..tail] -> exhaustive(pattern, tail)
        [] -> False
      }
    [head, ..rest], [letter, ..tail] -> head == letter && exhaustive(rest, tail)
    _, _ -> False
  }
}

pub fn wildcard_retry_agrees_with_exhaustive_matching_test() -> Nil {
  list.each(words(["a", "b", "*"], 5), fn(pattern) {
    list.each(words(["a", "b"], 4), fn(value) {
      cache_ttl.matches_glob(pattern, value)
      |> should.equal(exhaustive(
        string.to_graphemes(pattern),
        string.to_graphemes(value),
      ))
    })
  })
}

pub fn repeated_wildcards_fail_without_exponential_backtracking_test() -> Nil {
  let pattern = string.repeat("*a", 24) <> "b"
  cache_ttl.matches_glob(pattern, string.repeat("a", 48))
  |> should.be_false
}

pub fn wildcard_matches_unicode_graphemes_and_only_star_is_special_test() -> Nil {
  cache_ttl.matches_glob("É*👩‍💻?", "éclair👩‍💻?") |> should.be_true
  cache_ttl.matches_glob("é*", "éclair") |> should.be_true
  cache_ttl.matches_glob("a?", "ab") |> should.be_false
  cache_ttl.matches_glob("[ab]", "a") |> should.be_false
}
