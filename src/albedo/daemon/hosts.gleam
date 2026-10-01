//// `GET /hosts`: the hosts the folder picker completes, from the
//// workspaces of sessions (ranked the way the picker ranks recent folders)
//// and the `Host` entries of ssh config. Each carries its cached probe
//// state when there is one; listing never probes.

import albedo/daemon/conversation
import albedo/harness/location
import albedo/harness/ssh
import gleam/dict
import gleam/float
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}

pub fn list(sessions: List(conversation.Info), now: Int) -> Json {
  let recent =
    sessions
    |> list.fold(dict.new(), fn(scores, info) {
      case location.parse(info.cwd) {
        Ok(location.Remote(..) as at) ->
          case location.ssh_target(at) {
            Ok(target) ->
              dict.upsert(scores, target, fn(entry) {
                let weight = frecency(info.last_assistant_at, now)
                case entry {
                  Some(#(at, score)) -> #(at, score +. weight)
                  None -> #(at, weight)
                }
              })
            Error(Nil) -> scores
          }
        _ -> scores
      }
    })
    |> dict.to_list
    |> list.sort(fn(a, b) { float.compare(b.1.1, a.1.1) })
    |> list.map(fn(entry) { #(entry.0, entry.1.0, "recent") })
  let named = list.map(recent, fn(entry) { entry.0 })
  let configured =
    ssh.config_hosts()
    |> list.filter(fn(host) { !list.contains(named, host) })
    |> list.filter_map(fn(host) {
      case location.parse(host <> ":/") {
        Ok(at) -> Ok(#(host, at, "config"))
        Error(_) -> Error(Nil)
      }
    })
  json.object([
    #(
      "hosts",
      json.array(list.append(recent, configured), fn(entry) {
        let #(target, at, source) = entry
        let state = case ssh.known_state(target) {
          Some(state) -> [#("state", json.string(state))]
          None -> []
        }
        json.object([
          #("host", json.string(target)),
          #("label", json.nullable(location.label(at), json.string)),
          #("source", json.string(source)),
          ..state
        ])
      }),
    ),
  ])
}

/// The picker's weight for one session: 4 within the hour, halving past a
/// day, a week and a month.
fn frecency(last: Option(Int), now: Int) -> Float {
  case last {
    Some(at) -> weigh(now - at, [3600, 86_400, 604_800, 2_592_000], 4.0)
    None -> 0.25
  }
}

fn weigh(age: Int, limits: List(Int), weight: Float) -> Float {
  case limits {
    [within, ..rest] if age >= within -> weigh(age, rest, weight /. 2.0)
    _ -> weight
  }
}
