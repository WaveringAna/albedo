//// Encoded byte boundaries and the first excluded item must stop traversal.
//// E2E cannot observe redundant encoder calls or force catalog item boundaries.

import albedo/daemon/http_api as api
import gleam/json
import gleam/string

pub fn bounded_items_retain_the_measured_prefix_test() -> Nil {
  let kept =
    api.bounded_items([1, 2, 3], 1, 0, fn(item) {
      case item {
        3 -> panic as "encoding continued after the first excluded item"
        _ -> json.int(item)
      }
    })
  let assert [#(1, encoded)] = kept
  let assert "1" = json.to_string(encoded)
  let assert [] = api.bounded_items([1], 1, 1, json.int)
  let assert [#(1, _)] = api.bounded_items([1], 2, 1, json.int)
  Nil
}

pub fn catalog_limits_include_separator_bytes_test() -> Nil {
  let assert Ok([]) = api.bounded_catalog([json.int(1)], 1)
  let assert Ok([_]) = api.bounded_catalog([json.int(1)], 2)
  let oversized = json.string(string.repeat("x", 65_535))
  let assert Error(api.Failure(503, "catalog_item_unavailable", _)) =
    api.bounded_catalog([oversized], 100_000)
  let assert Ok([]) = api.bounded_catalog([], 0)
  Nil
}
