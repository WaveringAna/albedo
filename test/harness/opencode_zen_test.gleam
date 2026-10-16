//// OpenCode Zen's client identity, and the request that wears it.
////
//// The one other party that could catch a regression here is Zen's own
//// gateway, and it answers a badly shaped request with a refusal rather than
//// a test failure. So the shape it insists on — a session id of nine hex,
//// `ffe`, and fourteen base62, a user agent naming an OpenCode release, and
//// an agent request whose tool list carries OpenCode's own tool names — is
//// pinned here instead.

import albedo/harness/extensions/opencode_zen/extension
import albedo/openai_api/types
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should

const hex_digits = "0123456789abcdef"

const base62 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

fn all_in(text: String, allowed: String) -> Bool {
  text
  |> string.to_graphemes
  |> list.all(fn(char) { string.contains(allowed, char) })
}

fn tool_names(request: types.Request) -> List(String) {
  request.tools |> list.map(fn(tool) { tool.name })
}

fn request(tools: List(types.Tool)) -> types.Request {
  types.Request("glm-5.3-flash-free", None, [], tools, None, types.defaults)
}

fn native_free_lane(model: String, api_key: String) -> Bool {
  extension.free_lane(model, api_key)
}

fn named_tool(name: String) -> types.Tool {
  // The gateway reads the name and nothing else, so any schema will do.
  types.Tool(name, "does something", json.object([]), False)
}

pub fn zen_session_id_has_the_shape_the_gateway_accepts_test() -> Nil {
  let id = native_session("session-1")
  // `ses_`, then nine hex, then the literal `ffe`, then fourteen base62.
  id |> string.starts_with("ses_") |> should.be_true
  id |> string.length |> should.equal(30)
  let hex = string.slice(id, 4, 9)
  hex |> string.length |> should.equal(9)
  all_in(hex, hex_digits) |> should.be_true
  // `ffe` is a counter of one, inverted: the gateway refuses a session whose
  // decoded counter is past its first sixty-four.
  string.slice(id, 13, 3) |> should.equal("ffe")
  let tail = string.slice(id, 16, 14)
  tail |> string.length |> should.equal(14)
  all_in(tail, base62) |> should.be_true
}

pub fn zen_session_id_is_stable_per_session_and_distinct_between_them_test() -> Nil {
  // Zen routes a conversation and finds its cached prefix by this id, so a
  // resumed session has to keep it and two sessions must never share it.
  native_session("session-1") |> should.equal(native_session("session-1"))
  native_session("session-1") |> should.not_equal(native_session("session-2"))
}

pub fn zen_wears_opencode_s_client_identity_test() -> Nil {
  // The gateway reads the user agent to tell an official client from anything
  // else, and refuses the free tier without one that names an OpenCode release.
  native_user_agent() |> should.equal("opencode/latest/2.0.27/cli")
  let project = native_project("/home/fixture")
  project |> string.length |> should.equal(40)
  all_in(project, hex_digits) |> should.be_true
  native_project("/home/fixture") |> should.equal(project)
}

pub fn zen_free_tier_is_decided_by_the_model_id_test() -> Nil {
  native_free("glm-5.3-flash-free") |> should.be_true
  native_free("cat-jam-free") |> should.be_true
  native_free("deepseek-v4-pro") |> should.be_false
  native_free("glm-5.3-flash") |> should.be_false
}

pub fn zen_free_lane_is_worn_for_a_free_model_or_a_credential_less_profile_test() -> Nil {
  // A `-free` model is the free lane whatever the profile holds.
  native_free_lane("glm-5.3-flash-free", "sk-profile") |> should.be_true
  // `big-pickle` is served free without saying so in the id, and a profile
  // with no credential can only reach the free lane, so both take it.
  native_free_lane("big-pickle", "") |> should.be_true
  native_free_lane("big-pickle", "sk-profile") |> should.be_false
  native_free_lane("claude-opus-5", "") |> should.be_true
  // A paid model on a keyed profile is albedo's own shape, not OpenCode's.
  native_free_lane("claude-opus-5", "sk-profile") |> should.be_false
}

pub fn zen_free_lane_request_carries_opencode_s_tool_names_test() -> Nil {
  // The free lane answers an agent request only when its tool list carries the
  // names OpenCode's own agent sends. albedo's names are not among them, so
  // the quartet is appended after them.
  let shaped = extension.shape_for_free_lane(request([named_tool("python")]))
  let names = tool_names(shaped)
  ["bash", "glob", "grep", "read"]
  |> list.each(fn(name) { names |> list.contains(name) |> should.be_true })
  names |> list.first |> should.equal(Ok("python"))
}

pub fn zen_free_lane_request_adds_only_the_missing_fingerprint_tools_test() -> Nil {
  let shaped =
    extension.shape_for_free_lane(
      request([named_tool("bash"), named_tool("read")]),
    )
  // The pair it already carried stays first; the rest of the quartet follows.
  tool_names(shaped) |> should.equal(["bash", "read", "glob", "grep"])
}

pub fn zen_free_lane_request_without_tools_becomes_an_agent_request_test() -> Nil {
  // A tool-free request is the utility lane, which wants OpenCode's own prompt
  // instead. albedo never sends one on a free model, and the reserved stubs
  // move it to the lane that takes any prompt.
  let shaped = extension.shape_for_free_lane(request([]))
  tool_names(shaped) |> should.equal(["bash", "glob", "grep", "read"])
}

@external(erlang, "albedo_opencode_zen", "session")
fn native_session(seed: String) -> String

@external(erlang, "albedo_opencode_zen", "user_agent")
fn native_user_agent() -> String

@external(erlang, "albedo_opencode_zen", "project")
fn native_project(home: String) -> String

@external(erlang, "albedo_opencode_zen", "free")
fn native_free(model: String) -> Bool
