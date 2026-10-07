//// The user's provider order, kept in the `web-search` section of
//// extensions.json as `order` (names, first tried first) and `off` (names
//// never tried). A provider the order leaves out follows the named ones, in
//// registry order.

import albedo/harness/settings
import albedo/harness/web_search
import gleam/dynamic/decode
import gleam/list
import gleam/result

pub type Preference {
  Preference(order: List(String), off: List(String))
}

/// One provider in the user's order, and whether it is tried.
pub type Ranked {
  Ranked(provider: web_search.Provider, on: Bool)
}

pub type Refusal {
  Unknown
  Unsaved(reason: String)
}

pub type Change {
  Up
  Down
  Toggle
}

pub fn load() -> Result(Preference, String) {
  settings.load(
    "web-search",
    {
      use order <- decode.optional_field(
        "order",
        [],
        decode.list(decode.string),
      )
      use off <- decode.optional_field("off", [], decode.list(decode.string))
      decode.success(Preference(order, off))
    },
    Preference([], []),
  )
}

pub fn ranked(
  providers: List(web_search.Provider),
  preference: Preference,
) -> List(Ranked) {
  let named =
    list.filter_map(preference.order, fn(name) {
      list.find(providers, fn(provider) { provider.name == name })
    })
  let rest =
    list.filter(providers, fn(provider) {
      !list.contains(preference.order, provider.name)
    })
  list.append(named, rest)
  |> list.map(fn(provider) {
    Ranked(provider, !list.contains(preference.off, provider.name))
  })
}

/// The providers in the order a search tries them.
pub fn tried(ranked: List(Ranked)) -> List(web_search.Provider) {
  ranked
  |> list.filter(fn(entry) { entry.on })
  |> list.map(fn(entry) { entry.provider })
}

/// `ranked` after `change` to the provider called `name`, saved.
pub fn apply(
  ranked: List(Ranked),
  name: String,
  change: Change,
) -> Result(List(Ranked), Refusal) {
  use index <- result.try(
    list.index_map(ranked, fn(entry, index) { #(entry.provider.name, index) })
    |> list.key_find(name)
    |> result.replace_error(Unknown),
  )
  let changed = case change {
    Up -> swap(ranked, index - 1)
    Down -> swap(ranked, index)
    Toggle ->
      list.map(ranked, fn(entry) {
        case entry.provider.name == name {
          True -> Ranked(..entry, on: !entry.on)
          False -> entry
        }
      })
  }
  save(changed) |> result.map_error(Unsaved) |> result.replace(changed)
}

/// `ranked` with the entries at `index` and `index + 1` traded places; the
/// same list when either is out of range.
fn swap(ranked: List(Ranked), index: Int) -> List(Ranked) {
  case index < 0, list.split(ranked, index) {
    False, #(before, [first, second, ..after]) ->
      list.flatten([before, [second, first], after])
    _, _ -> ranked
  }
}

fn save(ranked: List(Ranked)) -> Result(Nil, String) {
  save_selection(
    settings.home(),
    list.map(ranked, fn(entry) { #(entry.provider.name, entry.on) }),
  )
}

@external(erlang, "albedo_web_search_settings", "save")
fn save_selection(
  home: String,
  selected: List(#(String, Bool)),
) -> Result(Nil, String)
